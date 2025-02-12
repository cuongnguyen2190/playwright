#!/bin/bash
set -e
set +x

RUST_VERSION="1.59.0"
CBINDGEN_VERSION="0.24.3"

trap "cd $(pwd -P)" EXIT

cd "$(dirname "$0")"
SCRIPT_FOLDER="$(pwd -P)"
source "${SCRIPT_FOLDER}/../utils.sh"

if [[ ! -z "${FF_CHECKOUT_PATH}" ]]; then
  cd "${FF_CHECKOUT_PATH}"
  echo "WARNING: checkout path from FF_CHECKOUT_PATH env: ${FF_CHECKOUT_PATH}"
else
  cd "$HOME/firefox"
fi

args=("$@")
IS_FULL=""
IS_JUGGLER=""
IS_LINUX_ARM64=""
IS_DEBUG=""
for ((i="${#args[@]}"-1; i >= 0; --i)); do
    case ${args[i]} in
        --full) IS_FULL="1"; unset args[i]; ;;
        --juggler) IS_JUGGLER="1"; unset args[i]; ;;
        --linux-arm64) IS_LINUX_ARM64="1"; unset args[i]; ;;
        --debug) IS_DEBUG="1"; unset args[i]; ;;
    esac
done

if [[ -n "${IS_JUGGLER}" && -n "${IS_FULL}" ]]; then
  echo "ERROR: either --full or --juggler is allowed"
  exit 1
fi

echo "== BUILD CONFIGURATION =="
if [[ -n "${IS_FULL}" ]]; then
  echo "- build type: FULL"
elif [[ -n "${IS_JUGGLER}" ]]; then
  echo "- build type: JUGGLER"
else
  echo "- build type: INCREMENTAL"
fi

if [[ -n "${IS_DEBUG}" ]]; then
  echo "- debug: YES"
else
  echo "- debug: NO"
fi

if [[ -n "${IS_LINUX_ARM64}" ]]; then
  echo "- linux aarch64: YES"
else
  echo "- linux aarch64: NO"
fi
echo "========================="

rm -rf .mozconfig

if is_mac; then
  selectXcodeVersionOrDie $(node "${SCRIPT_FOLDER}/../get_xcode_version.js" firefox)
  echo "-- building on Mac"
elif is_linux; then
  echo "-- building on Linux"
elif is_win; then
  echo "ac_add_options --disable-update-agent" >> .mozconfig
  echo "ac_add_options --disable-default-browser-agent" >> .mozconfig
  echo "ac_add_options --disable-maintenance-service" >> .mozconfig

  echo "-- building win64 build on MINGW"
  echo "ac_add_options --target=x86_64-pc-mingw32" >> .mozconfig
  echo "ac_add_options --host=x86_64-pc-mingw32" >> .mozconfig
  DLL_FILE=$("C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" -latest -find '**\Redist\MSVC\*\x64\**\vcruntime140.dll')
  WIN32_REDIST_DIR=$(dirname "$DLL_FILE")
  if ! [[ -d $WIN32_REDIST_DIR ]]; then
    echo "ERROR: cannot find MS VS C++ redistributable $WIN32_REDIST_DIR"
    exit 1;
  fi
else
  echo "ERROR: cannot upload on this platform!" 1>&2
  exit 1;
fi

if [[ -n "${IS_LINUX_ARM64}" ]]; then
  echo "ac_add_options --target=aarch64-linux-gnu" >> .mozconfig
fi

if is_linux "debian" 11; then
  # There's no pre-built wasi sysroot for Debian 11.
  echo "ac_add_options --without-wasm-sandboxed-libraries" >> .mozconfig
fi

OBJ_FOLDER="obj-build-playwright"
echo "mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/${OBJ_FOLDER}" >> .mozconfig
echo "ac_add_options --disable-crashreporter" >> .mozconfig
echo "ac_add_options --disable-backgroundtasks" >> .mozconfig

if [[ -n "${IS_DEBUG}" ]]; then
  echo "ac_add_options --enable-debug" >> .mozconfig
  echo "ac_add_options --enable-debug-symbols" >> .mozconfig
else
  echo "ac_add_options --enable-release" >> .mozconfig
fi

if is_mac || is_win; then
  # This options is only available on win and mac.
  echo "ac_add_options --disable-update-agent" >> .mozconfig
fi

if [[ -z "${IS_JUGGLER}" ]]; then
  # TODO: rustup is not in the PATH on Windows
  if command -v rustup >/dev/null; then
    # We manage Rust version ourselves.
    echo "-- Using rust v${RUST_VERSION}"
    rustup install "${RUST_VERSION}"
    rustup default "${RUST_VERSION}"
  fi

  # TODO: cargo is not in the PATH on Windows
  if command -v cargo >/dev/null; then
    echo "-- Using cbindgen v${CBINDGEN_VERSION}"
    cargo install cbindgen --version "${CBINDGEN_VERSION}"
  fi
fi

if [[ -n "${IS_FULL}" ]]; then
  # This is a slow but sure way to get all the necessary toolchains.
  # However, it will not work if tree is dirty.
  # Bail out if git repo is dirty.
  if [[ -n $(git status -s --untracked-files=no) ]]; then
    echo "ERROR: dirty GIT state - commit everything and re-run the script."
    exit 1
  fi

  # 1. We have a --single-branch checkout, so we have to add a "master" branch and fetch it
  git remote set-branches --add browser_upstream master
  git fetch browser_upstream master
  # 2. Checkout the master branch and run bootstrap from it.
  git checkout browser_upstream/master
  SHELL=/bin/sh ./mach --no-interactive bootstrap --application-choice=browser
  git checkout -

  if [[ ! -z "${WIN32_REDIST_DIR}" ]]; then
    # Having this option in .mozconfig kills incremental compilation.
    echo "export WIN32_REDIST_DIR=\"$WIN32_REDIST_DIR\"" >> .mozconfig
  fi
fi

# Remove the cbindgen from mozbuild to rely on the one we install manually.
# See https://github.com/microsoft/playwright/issues/15174
if is_win; then
  rm -rf "${USERPROFILE}\\.mozbuild\\cbindgen"
else
  rm -rf "${HOME}/.mozbuild/cbindgen"
fi


if [[ -n "${IS_JUGGLER}" ]]; then
  ./mach build faster
else
  export MOZ_AUTOMATION=1
  # Use winpaths instead of unix paths on Windows.
  # note: 'cygpath' is not available in MozBuild shell.
  if is_win; then
    export MOZ_FETCHES_DIR="${USERPROFILE}\\.mozbuild"
  else
    export MOZ_FETCHES_DIR="${HOME}/.mozbuild"
  fi
  ./mach build
  if is_mac; then
    FF_DEBUG_BUILD="${IS_DEBUG}" node "${SCRIPT_FOLDER}"/install-preferences.js "$PWD"/${OBJ_FOLDER}/dist
  else
    FF_DEBUG_BUILD="${IS_DEBUG}" node "${SCRIPT_FOLDER}"/install-preferences.js "$PWD"/${OBJ_FOLDER}/dist/bin
  fi
fi


