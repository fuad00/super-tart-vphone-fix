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
PATCH_OEMS_DIR="${REPO_ROOT}/patch_oems"
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
    git -C "${REPO_ROOT}" submodule update --init --recursive
    ok "submodules ready"
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
    ensure_dir "${PATCH_OEMS_DIR}"

    export PKG_CONFIG_PATH="${LOCAL_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export CFLAGS="-I${LOCAL_PREFIX}/include ${CFLAGS:-}"
    export CXXFLAGS="-I${LOCAL_PREFIX}/include ${CXXFLAGS:-}"
    export LDFLAGS="-L${LOCAL_PREFIX}/lib ${LDFLAGS:-}"
    export PATH="${LOCAL_PREFIX}/bin:${PATH}"
}

# ── build functions ──────────────────────────────────────────────────────────

# Copy source to patch_oems/ for a clean out-of-submodule build.
# This avoids polluting the submodule working tree.
setup_build_dir() {
    local name="$1"
    local src="${OEMS_DIR}/${name}"
    local dst="${PATCH_OEMS_DIR}/${name}"

    if [ -d "${dst}" ]; then
        rm -rf "${dst}"
    fi
    cp -a "${src}" "${dst}"
    # detach from submodule git
    rm -rf "${dst}/.git"
    echo "${dst}"
}

build_libgeneral() {
    log "building libgeneral..."
    local dir
    dir="$(setup_build_dir libgeneral)"

    pushd "${dir}" >/dev/null
    ./autogen.sh
    ./configure --prefix="${LOCAL_PREFIX}"
    make -j"${JOBS}"
    make install
    popd >/dev/null

    ok "libgeneral installed to ${LOCAL_PREFIX}"
}

build_img4tool() {
    log "building img4tool..."
    local dir
    dir="$(setup_build_dir img4tool)"

    pushd "${dir}" >/dev/null
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
    local dir
    dir="$(setup_build_dir img4lib)"

    pushd "${dir}" >/dev/null
    # on macOS: use CommonCrypto + libcompression (no external deps)
    make clean 2>/dev/null || true
    make COMMONCRYPTO=1 CC=clang -j"${JOBS}"
    popd >/dev/null

    cp -f "${dir}/img4" "${BIN_DIR}/img4"
    ok "img4 -> ${BIN_DIR}/img4"
}

build_trustcache() {
    log "building trustcache..."
    local dir
    dir="$(setup_build_dir trustcache)"

    # openssl flags from pkg-config
    local ssl_cflags ssl_libs
    ssl_cflags="$(pkg-config --cflags openssl)"
    ssl_libs="$(pkg-config --libs openssl)"

    pushd "${dir}" >/dev/null
    make clean 2>/dev/null || true
    make OPENSSL=1 \
         CFLAGS="${ssl_cflags}" \
         LDFLAGS="${ssl_libs}" \
         -j"${JOBS}"
    popd >/dev/null

    cp -f "${dir}/trustcache" "${BIN_DIR}/trustcache"
    ok "trustcache -> ${BIN_DIR}/trustcache"
}

build_libirecovery() {
    log "building libirecovery (forked)..."
    local dir
    dir="$(setup_build_dir libirecovery)"

    pushd "${dir}" >/dev/null
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
    local dir
    dir="$(setup_build_dir idevicerestore)"

    pushd "${dir}" >/dev/null
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
    local dir
    dir="$(setup_build_dir super-tart)"

    pushd "${dir}" >/dev/null
    swift build -c release 2>&1 | tail -5
    popd >/dev/null

    cp -f "${dir}/.build/release/tart" "${BIN_DIR}/tart"
    ok "tart -> ${BIN_DIR}/tart"
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

    echo ""
    log "all tools built successfully:"
    ls -lh "${BIN_DIR}"/img4 "${BIN_DIR}"/img4tool "${BIN_DIR}"/trustcache \
           "${BIN_DIR}"/irecovery "${BIN_DIR}"/idevicerestore "${BIN_DIR}"/tart \
        2>/dev/null || true
    echo ""
    log "run 'source setup_env.sh' to activate the environment"
}

main "$@"
