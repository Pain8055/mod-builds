#!/usr/bin/env bash
set -euo pipefail
[[ "${BUILD:-}" =~ ^[0-9a-f]{40}$ ]] || { echo "Not a build: ${BUILD:-}"; exit 1; }
[[ "${PROFILE:-}" =~ ^(fast|quick)$ ]] || { echo "Not a profile: ${PROFILE:-}"; exit 1; }
triple=$(python3 -I -c 'import os, sys; sys.path.insert(0, "scripts"); import store; print(store.TARGETS[os.environ["ABI"]])')
root=$HOME/store
NDK=28.2.13676358

rm -rf "$root"
git init -q "$root/source"
git -C "$root/source" fetch -q --depth 1 https://github.com/starling-client/starling "$BUILD"
git -C "$root/source" checkout -q --detach FETCH_HEAD

if [ ! -d "$HOME/android/ndk/$NDK" ]; then
  (yes || true) | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$HOME/android" \
    --install "ndk;$NDK" "build-tools;35.0.0" "platforms;android-36" | tail -3
fi
export ANDROID_HOME=$HOME/android ANDROID_NDK_HOME=$HOME/android/ndk/$NDK

cd "$root/source"
rm -rf "$HOME/.rustup" "$HOME/.cargo"
curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --default-toolchain none
. "$HOME/.cargo/env"
GITHUB_ENV='' bash tools/ci/rustup_install.sh --profile minimal --component rust-src --target "$triple"
cargo install cargo-ndk --version 3.5.4 --locked

if python3 tools/prebuilt_game.py stage --help >/dev/null 2>&1; then
  started=$(date +%s)
  staged=$(python3 tools/prebuilt_game.py stage "$root/staging" | tail -1)
  rsync -a --delete --exclude .git --exclude target "$staged/" ./
  mv "$root/staging/stage-in" .unstaged
  rm -rf "$root/staging"
  CARGO_TARGET_DIR=target/host-tools cargo build -q --release -p sunrise-native-build --bin sunrise-android-patch
  SUNRISE_ANDROID_PATCH_HOME=$PWD/.android-patch-home target/host-tools/release/sunrise-android-patch --tool
  echo "The staged game and the patch tool: $(( $(date +%s) - started )) s"
fi

python3 tools/android_native_sdk.py prepare
export HORIZON_GAME_BUILD_ID=$BUILD SUNRISE_GAME_BUILD_ID=$BUILD
started=$(date +%s)

env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/usr/bin:/bin" LANG=C.UTF-8 \
  ANDROID_HOME="$ANDROID_HOME" ANDROID_NDK_HOME="$ANDROID_NDK_HOME" \
  HORIZON_GAME_BUILD_ID="$BUILD" SUNRISE_GAME_BUILD_ID="$BUILD" \
  RUSTFLAGS="-C prefer-dynamic" \
  python3 packaging/android/build_apk.py --abi "$ABI" --profile "$PROFILE" --library-only

echo "The game's build: $(( $(date +%s) - started )) s"

shipped=$root/shipped
mkdir -p "$shipped"
RUSTFLAGS="-C prefer-dynamic" python3 - "$triple" "$PROFILE" "$shipped" <<'EOF'
import os, pathlib, shutil, sys
sys.path.insert(0, "packaging/android")
import build_apk
triple, profile, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
built = pathlib.Path("target") / triple / ("debug" if profile == "dev" else profile) / f"lib{build_apk.LIBRARY}.so"
shutil.copyfile(pathlib.Path("target/android") / f"lib{build_apk.LIBRARY}.so", out / f"lib{build_apk.LIBRARY}.so")
build_apk.rust_dylibs(pathlib.Path(os.environ["ANDROID_NDK_HOME"]), built.resolve(), out)
EOF
(cd "$shipped" && sha256sum ./*.so)

if [ -n "${APK:-}" ]; then
  [[ "$APK" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/ ]] \
    || { echo "An APK is a GitHub release's download, not $APK"; exit 1; }
  curl -fsSL --retry 5 -o "$RUNNER_TEMP/nightly.apk" "$APK"
  mkdir -p "$RUNNER_TEMP/apk"
  unzip -q -o "$RUNNER_TEMP/nightly.apk" "lib/$ABI/*.so" -d "$RUNNER_TEMP/apk"
  differ=0
  for library in "$shipped"/*.so; do
    name=$(basename "$library")
    theirs=$RUNNER_TEMP/apk/lib/$ABI/$name
    if [ ! -f "$theirs" ]; then
      echo "::error::$name is not in the APK"; differ=1
    elif ! cmp -s "$library" "$theirs"; then
      echo "::error::$name differs from the APK's: a mod built here would not load on the phone"; differ=1
    fi
  done
  [ "$differ" = 0 ] || exit 1
  echo "Every library of the game is the APK's."
fi

mv "$HOME/.cargo" "$root/cargo"
du -sh "$root/source/target" "$root/cargo" "$HOME/android" "$HOME/.rustup"
