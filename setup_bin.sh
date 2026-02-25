#!/bin/bash
# setup_bin.sh — Build all OEM tools from submodules and install to bin/.
#
# Prerequisites (macOS):
#   brew install automake autoconf libtool pkg-config \
#                libplist openssl@3 libimobiledevice-glue \
#                libimobiledevice libtatsu libzip curl
#
# Usage:
#   bash setup_bin.sh      # build everything (also sets up venv)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${REPO_ROOT}/bin"
LOCAL_PREFIX="${REPO_ROOT}/.local"
OEMS_DIR="${REPO_ROOT}/oems"
VENV_DIR="${REPO_ROOT}/.venv"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; }
die()  { err "$@"; exit 1; }

ensure_dir() { mkdir -p "$1"; }

# ── preflight ────────────────────────────────────────────────────────────────

check_prerequisites() {
    log "checking prerequisites..."

    local missing=()
    for cmd in git make clang pkg-config automake autoconf libtool swift python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ ${#missing[@]} -ne 0 ]; then
        die "missing commands: ${missing[*]}"
    fi

    # check brew packages via pkg-config
    local pkgs=(libplist-2.0 openssl libimobiledevice-glue-1.0
                libimobiledevice-1.0 libtatsu-1.0 libzip)
    local missing_pkgs=()
    for pkg in "${pkgs[@]}"; do
        pkg-config --exists "$pkg" 2>/dev/null || missing_pkgs+=("$pkg")
    done

    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        err "missing pkg-config packages: ${missing_pkgs[*]}"
        echo "  install with:"
        echo "    brew install libplist openssl@3 libimobiledevice-glue libimobiledevice libtatsu libzip"
        die "install missing packages and re-run."
    fi

    ok "all prerequisites satisfied"
}

check_submodules() {
    log "checking submodules..."
    # only init submodules we actually build (skip SSHRD_Script/sshtars etc.)
    local build_modules=(libgeneral img4lib img4tool trustcache
                         libirecovery idevicerestore super-tart)
    for mod in "${build_modules[@]}"; do
        local mod_path="${OEMS_DIR}/${mod}"
        if [ -d "${mod_path}/.git" ] || [ -f "${mod_path}/.git" ]; then
            # already cloned — clean build artifacts
            git -C "${mod_path}" checkout . 2>/dev/null || true
            git -C "${mod_path}" clean -fdx 2>/dev/null || true
        else
            git -C "${REPO_ROOT}" submodule update --init -- "oems/${mod}"
        fi
    done

    # reset all oems/ submodule pointers (including nested ones like
    # SSHRD_Script/sshtars) back to their committed state so oems/ stays
    # pristine — any local modifications belong in patch_oems/ or patch_scripts/
    log "resetting oems/ submodule pointers to committed state..."
    git -C "${REPO_ROOT}" submodule update --init --recursive -- oems/
    ok "submodules ready (all oems/ clean)"
}

# ── python venv ──────────────────────────────────────────────────────────────

setup_venv() {
    log "setting up python venv..."
    if [ -d "${VENV_DIR}" ]; then
        ok "venv already exists at ${VENV_DIR}"
    else
        python3 -m venv "${VENV_DIR}"
        ok "created venv at ${VENV_DIR}"
    fi

    source "${VENV_DIR}/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet -r "${REPO_ROOT}/requirements.txt"
    ok "python dependencies installed"
}

# ── prepare build dirs ───────────────────────────────────────────────────────

prepare() {
    log "preparing build directories..."
    ensure_dir "${BIN_DIR}"
    ensure_dir "${LOCAL_PREFIX}/bin"
    ensure_dir "${LOCAL_PREFIX}/lib/pkgconfig"
    ensure_dir "${LOCAL_PREFIX}/include"

    export PKG_CONFIG_PATH="${LOCAL_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export CFLAGS="-I${LOCAL_PREFIX}/include ${CFLAGS:-}"
    export CXXFLAGS="-I${LOCAL_PREFIX}/include ${CXXFLAGS:-}"
    export LDFLAGS="-L${LOCAL_PREFIX}/lib ${LDFLAGS:-}"
    export PATH="${LOCAL_PREFIX}/bin:${PATH}"
}

# ── build functions ──────────────────────────────────────────────────────────
# Build directly in oems/ submodule trees so autotools version detection
# (git rev-list --count HEAD) works correctly. Build artifacts are cleaned
# by check_submodules on subsequent runs.

build_libgeneral() {
    log "building libgeneral..."
    pushd "${OEMS_DIR}/libgeneral" >/dev/null
    ./autogen.sh
    ./configure --prefix="${LOCAL_PREFIX}"
    make -j"${JOBS}"
    make install
    popd >/dev/null
    ok "libgeneral installed to ${LOCAL_PREFIX}"
}

build_img4tool() {
    log "building img4tool..."
    pushd "${OEMS_DIR}/img4tool" >/dev/null
    mkdir -p m4
    if command -v glibtoolize >/dev/null 2>&1; then
        glibtoolize --copy --force
    elif command -v libtoolize >/dev/null 2>&1; then
        libtoolize --copy --force
    fi
    ./autogen.sh
    ./configure --prefix="${LOCAL_PREFIX}" \
        --without-libfwkeyfetch \
        --without-openssl
    make -j"${JOBS}"
    make install
    popd >/dev/null
    cp -f "${LOCAL_PREFIX}/bin/img4tool" "${BIN_DIR}/img4tool"
    ok "img4tool -> ${BIN_DIR}/img4tool"
}

build_img4lib() {
    log "building img4 (img4lib)..."
    pushd "${OEMS_DIR}/img4lib" >/dev/null
    make clean 2>/dev/null || true
    # macOS: CommonCrypto for crypto, libcompression for lzfse
    # /usr/lib/libcompression.dylib is in the shared cache on modern macOS,
    # so the Makefile wildcard check fails — override explicitly.
    make CC=clang \
         COMMONCRYPTO=1 \
         CFLAGS="-Wall -W -pedantic -Wno-variadic-macros -Wno-multichar \
                 -Wno-four-char-constants -Wno-unused-parameter -O2 -I. -g \
                 -DiOS10 -DDER_MULTIBYTE_TAGS=1 -DDER_TAG_SIZE=8 \
                 -D__unused=\"__attribute__((unused))\" \
                 -DUSE_COMMONCRYPTO -DUSE_LIBCOMPRESSION" \
         LDLIBS="-lcompression -framework Security -framework CoreFoundation" \
         -j"${JOBS}"
    popd >/dev/null
    cp -f "${OEMS_DIR}/img4lib/img4" "${BIN_DIR}/img4"
    ok "img4 -> ${BIN_DIR}/img4"
}

build_trustcache() {
    log "building trustcache..."
    local ssl_cflags ssl_libs
    ssl_cflags="$(pkg-config --cflags openssl)"
    ssl_libs="$(pkg-config --libs openssl)"

    pushd "${OEMS_DIR}/trustcache" >/dev/null
    make clean 2>/dev/null || true
    make OPENSSL=1 \
         CFLAGS="-DOPENSSL -DVERSION=2.0 ${ssl_cflags}" \
         LIBS="${ssl_libs}" \
         -j"${JOBS}"
    popd >/dev/null
    cp -f "${OEMS_DIR}/trustcache/trustcache" "${BIN_DIR}/trustcache"
    ok "trustcache -> ${BIN_DIR}/trustcache"
}

build_libirecovery() {
    log "building libirecovery (forked)..."
    pushd "${OEMS_DIR}/libirecovery" >/dev/null
    ./autogen.sh
    ./configure --prefix="${LOCAL_PREFIX}" --with-tools
    make -j"${JOBS}"
    make install
    popd >/dev/null
    cp -f "${LOCAL_PREFIX}/bin/irecovery" "${BIN_DIR}/irecovery"
    ok "irecovery -> ${BIN_DIR}/irecovery"
}

build_idevicerestore() {
    log "building idevicerestore..."
    pushd "${OEMS_DIR}/idevicerestore" >/dev/null
    ./autogen.sh
    ./configure --prefix="${LOCAL_PREFIX}"
    make -j"${JOBS}"
    make install
    popd >/dev/null
    cp -f "${LOCAL_PREFIX}/bin/idevicerestore" "${BIN_DIR}/idevicerestore"
    ok "idevicerestore -> ${BIN_DIR}/idevicerestore"
}

build_super_tart() {
    log "building super-tart (tart)..."
    local target="${OEMS_DIR}/super-tart/Sources/tart/VM.swift"
    patch_super_tart_vm "${target}"
    local spm_root="${REPO_ROOT}/.swiftpm"
    local spm_home="${REPO_ROOT}/.swift-home"
    mkdir -p "${spm_root}/config" "${spm_root}/security" "${spm_root}/cache" "${spm_root}/xdg-cache" "${spm_home}"
    pushd "${OEMS_DIR}/super-tart" >/dev/null
    # Use repo-local SwiftPM caches and disable sandbox to avoid macOS sandbox/cache issues.
    SWIFTPM_CONFIG_PATH="${spm_root}/config" \
    SWIFTPM_SECURITY_PATH="${spm_root}/security" \
    SWIFTPM_CACHE_PATH="${spm_root}/cache" \
    XDG_CACHE_HOME="${spm_root}/xdg-cache" \
    HOME="${spm_home}" \
    swift build -c release --disable-sandbox 2>&1 | tail -5
    popd >/dev/null
    cp -f "${OEMS_DIR}/super-tart/.build/release/tart" "${BIN_DIR}/tart"
    ok "tart -> ${BIN_DIR}/tart"
}

patch_super_tart_vm() {
    local target="$1"
    if [ ! -f "${target}" ]; then
        die "super-tart VM.swift not found at ${target}"
    fi

    log "patching super-tart VM.swift for vphone (VPHONE_MODE)..."
    TARGET="${target}" python3 - <<'PY'
from pathlib import Path
import os
import sys
import textwrap

path = Path(os.environ["TARGET"])
data = path.read_text()

if "VPHONE_MODE" in data:
    print("  ✓ VM.swift already patched")
    sys.exit(0)

needle_class = "class VM: NSObject, VZVirtualMachineDelegate, ObservableObject {\n"
if needle_class not in data:
    raise SystemExit("patch failed: class VM declaration not found")

insert_helpers = needle_class + textwrap.dedent("""\
  static private func vphoneEnabled() -> Bool {
    return ProcessInfo.processInfo.environment["VPHONE_MODE"] == "1"
  }

  // vzHardwareModel derives the VZMacHardwareModel config specific to the "platform type"
  // of the VM (currently only vresearch101 supported)
  static private func vzHardwareModel_VRESEARCH101() throws -> VZMacHardwareModel {
    var hw_model: VZMacHardwareModel

    guard let hw_descriptor = _VZMacHardwareModelDescriptor() else {
      fatalError("Failed to create hardware descriptor")
    }
    hw_descriptor.setPlatformVersion(3) // .appleInternal4 = 3
    hw_descriptor.setBoardID(0x90)
    hw_descriptor.setISA(2)
    hw_model = VZMacHardwareModel._hardwareModel(withDescriptor: hw_descriptor)

    guard hw_model.isSupported else {
        fatalError("VM hardware config not supported (model.isSupported = false)")
    }

    return hw_model
  }

""")
data = data.replace(needle_class, insert_helpers)

needle_platform = textwrap.dedent("""\
    // Platform
    configuration.platform = try vmConfig.platform.platform(nvramURL: nvramURL, needsNestedVirtualization: nested)

    // Display
    configuration.graphicsDevices = [vmConfig.platform.graphicsDevice(vmConfig: vmConfig)]
""")
if needle_platform not in data:
    raise SystemExit("patch failed: platform/display block not found")

replace_platform = textwrap.dedent("""\
    let vphoneMode = Self.vphoneEnabled()

    // Platform
    if vphoneMode {
      let vmRoot = nvramURL.deletingLastPathComponent()
      let sepstorageURL = vmRoot.appendingPathComponent("SEPStorage")
      let sepConfig = Dynamic._VZSEPCoprocessorConfiguration(storageURL: sepstorageURL)
      sepConfig.debugStub = Dynamic._VZGDBDebugStubConfiguration(port: 8001)
      Dynamic(configuration)._setCoprocessors([sepConfig.asObject])

      let pconf = VZMacPlatformConfiguration()
      pconf.hardwareModel = try vzHardwareModel_VRESEARCH101()

      let serial = Dynamic._VZMacSerialNumber.initWithString("AAAAAA1337")
      let identifier = Dynamic.VZMacMachineIdentifier._machineIdentifierWithECID(0x1111111111111111, serialNumber: serial.asObject)
      pconf.machineIdentifier = identifier.asObject as! VZMacMachineIdentifier

      pconf._setProductionModeEnabled(true)
      pconf.auxiliaryStorage = VZMacAuxiliaryStorage(url: nvramURL)
      configuration.platform = pconf
    } else {
      configuration.platform = try vmConfig.platform.platform(nvramURL: nvramURL, needsNestedVirtualization: nested)
    }

    // Display
    if vphoneMode {
      let graphics_config = VZMacGraphicsDeviceConfiguration()
      let displays_config = VZMacGraphicsDisplayConfiguration(
          widthInPixels: 1179,
          heightInPixels: 2556,
          pixelsPerInch: 460
      )
      graphics_config.displays.append(displays_config)
      configuration.graphicsDevices = [graphics_config]
    } else {
      configuration.graphicsDevices = [vmConfig.platform.graphicsDevice(vmConfig: vmConfig)]
    }
""")
data = data.replace(needle_platform, replace_platform)

needle_kb = textwrap.dedent("""\
    // Keyboard and mouse
    if suspendable, let platformSuspendable = vmConfig.platform.self as? PlatformSuspendable {
      configuration.keyboards = platformSuspendable.keyboardsSuspendable()
      configuration.pointingDevices = platformSuspendable.pointingDevicesSuspendable()
    } else {
      configuration.keyboards = vmConfig.platform.keyboards()
      configuration.pointingDevices = vmConfig.platform.pointingDevices()
    }
""")
if needle_kb not in data:
    raise SystemExit("patch failed: keyboard/mouse block not found")

replace_kb = textwrap.dedent("""\
    // Keyboard and mouse
    if vphoneMode {
      if #available(macOS 14, *) {
        let keyboard = VZUSBKeyboardConfiguration()
        configuration.keyboards = [keyboard]
      }
      configuration.pointingDevices = vmConfig.platform.pointingDevices()

      if #available(macOS 14, *) {
        let touch = _VZUSBTouchScreenConfiguration()
        Dynamic(configuration)._setMultiTouchDevices([touch])
      }
    } else if suspendable, let platformSuspendable = vmConfig.platform.self as? PlatformSuspendable {
      configuration.keyboards = platformSuspendable.keyboardsSuspendable()
      configuration.pointingDevices = platformSuspendable.pointingDevicesSuspendable()
    } else {
      configuration.keyboards = vmConfig.platform.keyboards()
      configuration.pointingDevices = vmConfig.platform.pointingDevices()
    }
""")
data = data.replace(needle_kb, replace_kb)

path.write_text(data)
print("  ✓ VM.swift patched")
PY
    ok "VM.swift patched"
}

install_homebrew_tools() {
    log "installing homebrew tools to bin/..."
    local tools=(ldid sshpass gtar iproxy)
    for tool in "${tools[@]}"; do
        local src
        src="$(command -v "$tool" 2>/dev/null || true)"
        if [ -z "$src" ]; then
            err "$tool not found — install with: brew install $tool"
            continue
        fi
        cp -f "$src" "${BIN_DIR}/$tool"
        chmod +x "${BIN_DIR}/$tool"
        ok "$tool -> ${BIN_DIR}/$tool"
    done
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
    log "setup_bin.sh — building all tools from oems/"
    echo ""

    check_prerequisites
    check_submodules
    setup_venv
    prepare

    # build order matters: dependencies first
    build_libgeneral          # library (no deps)
    build_img4lib             # standalone (CommonCrypto)
    build_img4tool            # depends on libgeneral
    build_trustcache          # standalone (OpenSSL)
    build_libirecovery        # depends on libimobiledevice-glue
    build_idevicerestore      # depends on libirecovery + many libs
    build_super_tart          # Swift Package Manager
    install_homebrew_tools    # ldid, sshpass, gtar, iproxy

    echo ""
    log "all tools built successfully:"
    ls -lh "${BIN_DIR}"/img4 "${BIN_DIR}"/img4tool "${BIN_DIR}"/trustcache \
           "${BIN_DIR}"/irecovery "${BIN_DIR}"/idevicerestore "${BIN_DIR}"/tart \
           "${BIN_DIR}"/ldid "${BIN_DIR}"/sshpass "${BIN_DIR}"/gtar \
           "${BIN_DIR}"/iproxy \
        2>/dev/null || true
    echo ""
    log "run 'source setup_env.sh' to activate the environment"
}

main "$@"
