#!/usr/bin/env bash
# Compile v2's base for game build BUILD and ABI: the APK's own Cargo build, as Starling's android-sdk workflow makes
# it (tools/android_native_sdk.py `prepare`, then build_apk.py with -C prefer-dynamic), so a mod's library builds
# beside it in a minute (android_native_sdk.py `mods`) against the very libraries the APK ships. Only trusted code
# runs here, and only store-base.yml writes this cache. Its folders are the cache's, so they never change:
# ~/store (the checkout with its target, and Cargo's home), ~/android, ~/.rustup.
#
# Given APK (a Nightly's APK on GitHub), each of the game's libraries built here is checked against the APK's: a mod
# built beside libraries that differ from the phone's would not load there.
set -euo pipefail
[[ "${BUILD:-}" =~ ^[0-9a-f]{40}$ ]] || { echo "Not a build: ${BUILD:-}"; exit 1; }
# The profile players' Nightlies are built with (android.yml: `fast`, as releases), or `quick` for tests.
[[ "${PROFILE:-}" =~ ^(fast\vert{}quick)$ ]] || { echo "Not a profile: ${PROFILE:-}"; exit 1; }
triple=$(python3 -I -c 'import os, sys; sys.path.insert(0, "scripts"); import store; print(store.TARGETS[os.environ["ABI"]])')
root=$HOME/store
NDK=28.2.13676358

rm -rf "$root"
git init -q "$root/source"
git -C "$root/source" fetch -q --depth 1 https://github.com/starling-client/starling "$BUILD"
git -C "$root/source" checkout -q --detach FETCH_HEAD

# The NDK, the build tools and the platform build_apk.py pins, where the sandbox finds them. store-base.yml installs
# them before `room.sh clean` deletes the runner's SDK, sdkmanager with it.
if [ ! -d "$HOME/android/ndk/$NDK" ]; then
  (yes || true) | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$HOME/android" \
    --install "ndk;$NDK" "build-tools;35.0.0" "platforms;android-36" | tail -3
fi
export ANDROID_HOME=$HOME/android ANDROID_NDK_HOME=$HOME/android/ndk/$NDK

cd "$root/source"
# The Rust the game pins (tools/ci/rust-version), with the std's source build_apk.py builds the std from.
rm -rf "$HOME/.rustup" "$HOME/.cargo"
curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --default-toolchain none
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
GITHUB_ENV='' bash tools/ci/rustup_install.sh --profile minimal --component rust-src --target "$triple"
cargo install cargo-ndk --version 3.5.4 --locked
# A game that stages (tools/prebuilt_game.py `stage`): the APK's arm64 game is built from its staged copy, a slot in
# each function (android.yml), so the base is too. The commit's unstaged source stays beside it (.unstaged), which
# a mixin mod's patch crate copies its functions out of, and sunrise-android-patch is built with the horizon-mixins
# tool fetched (.android-patch-home): the sandbox has no network (android_native_sdk.py `mods`, mod_lib.py).
if python3 tools/prebuilt_game.py stage --help >/dev/null 2>&1; then
  started=$(date +%s)
  staged=$(python3 tools/prebuilt_game.py stage "$root/staging" | tail -1)
  rsync -a --delete --exclude .git --exclude target "$staged/" ./
  mv "$root/staging/stage-in" .unstaged
  rm -rf "$root/staging"
  CARGO_TARGET_DIR=target/host-tools cargo build -q --release -p sunrise-native-build --bin sunrise-android-patch
  SUNRISE_ANDROID_PATCH_HOME=$PWD/.android-patch-home target/host-tools/release/sunrise-android-patch --tool
  echo "The staged game and the patch tool: $(($(date +%s) - started )) s"
fi
python3 tools/android_native_sdk.py prepare
# The game's build identity as each mod's build gives it (mod_lib.py): horizon-mod-host's build script reads it
# (rerun-if-env-changed), so a base built without it had Cargo build the whole game again for every mod, some 15
# minutes, though `git rev-parse HEAD` named the same commit (2026-11-20).
# Either naming: a game built on Sunrise reads SUNRISE_GAME_BUILD_ID.
export HORIZON_GAME_BUILD_ID=$BUILD SUNRISE_GAME_BUILD_ID=$BUILD
started=$(date +%s)
# In the environment each mod's build has (sandbox.sh's `env -i`), not the runner's own: the build scripts of
# android-activity and the like read the environment (cc's rerun-if-env-changed), so with a base built in the runner's,
# every build a phone asked for compiled android-activity, cpal, horizon-android and horizon-client again, ten minutes
# where the mod alone takes one (2026-11-22).
env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/usr/bin:/bin" LANG=C.UTF-8   ANDROID_HOME="$ANDROID_HOME" ANDROID_NDK_HOME="$ANDROID_NDK_HOME" HORIZON_GAME_BUILD_ID="$BUILD" SUNRISE_GAME_BUILD_ID="$BUILD"   RUSTFLAGS="-C prefer-dynamic"   python3 packaging/android/build_apk.py --abi "$ABI
