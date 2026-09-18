#!/usr/bin/env bash
# ============================================================================
#  setup-theos.sh — cài đặt toàn bộ môi trường build tweak iOS cho Theos
#  Dùng được cả trên máy local (Ubuntu/Debian) lẫn GitHub Actions runner.
#  Idempotent: chạy lại nhiều lần không gây lỗi.
#
#  Thành phần:
#    - Theos (core + makefiles + logos)
#    - iOS toolchain cho Linux (clang 19, L1ghtmann llvm-project — bản cho iOS)
#    - iPhoneOS16.5.sdk (theos/sdks)
#    - ldid (fake-sign dylib/bundle)
#    - deps hệ thống: build-essential fakeroot rsync unzip xz
#
#  Biến môi trường:
#    THEOS  (mặc định: $HOME/theos)     — thư mục theos
#    IOS_SDK (mặc định: iPhoneOS16.5.sdk)
# ============================================================================
set -euo pipefail

THEOS_DIR="${THEOS:-$HOME/theos}"
IOS_SDK="${IOS_SDK:-iPhoneOS16.5.sdk}"

# Pinned versions — tái lập được (reproducible)
TOOLCHAIN_TAG="main-update_3-eabca92"   # clang 19 iOS toolchain
TOOLCHAIN_ARCH="$(uname -m)"; [ "$TOOLCHAIN_ARCH" = "x86_64" ] && TOOLCHAIN_ARCH="x86_64"
TOOLCHAIN_URL="https://github.com/L1ghtmann/llvm-project/releases/download/${TOOLCHAIN_TAG}/iOSToolchain-${TOOLCHAIN_ARCH}.tar.xz"
SDKS_URL="https://github.com/theos/sdks/archive/master.zip"
LDID_URL="https://github.com/ProcursusTeam/ldid/releases/latest/download/ldid_linux_${TOOLCHAIN_ARCH}"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

# ----------------------------------------------------------------------------
# 0. System dependencies
# ----------------------------------------------------------------------------
log "Cài dependencies hệ thống (bỏ qua nếu đã có)"
if command -v apt-get >/dev/null 2>&1; then
    SUDO=""
    [ "$(id -u)" != "0" ] && SUDO="sudo"
    $SUDO apt-get update -y >/dev/null 2>&1 || true
    $SUDO apt-get install -y build-essential fakeroot rsync curl perl git unzip xz-utils ca-certificates >/dev/null 2>&1 || \
    $SUDO apt-get install -y build-essential fakeroot rsync curl perl git unzip xz-utils || true
fi

# ----------------------------------------------------------------------------
# 1. Theos core
# ----------------------------------------------------------------------------
if [ -d "$THEOS_DIR/makefiles" ]; then
    log "Theos đã có tại $THEOS_DIR — bỏ qua clone"
else
    log "Clone Theos"
    git clone --recursive https://github.com/theos/theos.git "$THEOS_DIR"
fi
mkdir -p "$THEOS_DIR/sdks" "$THEOS_DIR/toolchain"


# ----------------------------------------------------------------------------
# Optional: ROOTHIDE=1 ./setup-theos.sh  → thay theos bằng fork roothide/theos
# (auto-synced 100% với theos chính thức, cần để build THEOS_PACKAGE_SCHEME=roothide)
# ----------------------------------------------------------------------------
if [ "${ROOTHIDE:-0}" = "1" ]; then
    log "ROOTHIDE mode (roothide/theos fork): dùng fork roothide/theos"
    if [ -d "$THEOS_DIR/.git" ]; then
        CURRENT_URL="$(git -C "$THEOS_DIR" config remote.origin.url)"
        case "$CURRENT_URL" in
            *roothide/theos*) log "roothide/theos đã có — bỏ qua" ;;
            *) log "THEOS hiện tại là mainline — xoá để clone lại bằng fork roothide"
               rm -rf "$THEOS_DIR"
               git clone --recursive https://github.com/roothide/theos.git "$THEOS_DIR" ;;
        esac
    else
        git clone --recursive https://github.com/roothide/theos.git "$THEOS_DIR"
    fi
    mkdir -p "$THEOS_DIR/sdks" "$THEOS_DIR/toolchain"
fi

# ----------------------------------------------------------------------------
# 2. iOS toolchain (clang cho Linux nhắm arm64/arm64e Apple)
# ----------------------------------------------------------------------------
if [ -x "$THEOS_DIR/toolchain/linux/iphone/bin/clang" ]; then
    log "Toolchain đã có — bỏ qua"
else
    log "Tải iOS toolchain ($TOOLCHAIN_TAG, $TOOLCHAIN_ARCH) — ~120MB"
    curl -sL --retry 3 -o /tmp/iostoolchain.tar.xz "$TOOLCHAIN_URL"
    tar -xJf /tmp/iostoolchain.tar.xz -C "$THEOS_DIR/toolchain/"
    rm -f /tmp/iostoolchain.tar.xz
    [ -x "$THEOS_DIR/toolchain/linux/iphone/bin/clang" ] || { echo "Toolchain sai cấu trúc!"; exit 1; }
fi

# ----------------------------------------------------------------------------
# 3. iOS SDK
# ----------------------------------------------------------------------------
if [ -d "$THEOS_DIR/sdks/$IOS_SDK" ]; then
    log "SDK $IOS_SDK đã có — bỏ qua"
else
    log "Tải SDK $IOS_SDK"
    curl -sL --retry 3 -o /tmp/sdks.zip "$SDKS_URL"
    unzip -q /tmp/sdks.zip -d /tmp/sdks_x "*/${IOS_SDK}/*"
    mv "/tmp/sdks_x/sdks-master/$IOS_SDK" "$THEOS_DIR/sdks/"
    rm -rf /tmp/sdks.zip /tmp/sdks_x
fi

# ----------------------------------------------------------------------------
# 4. ldid (fake-sign)
# ----------------------------------------------------------------------------
if ! command -v ldid >/dev/null 2>&1; then
    log "Cài ldid"
    if [ -w /usr/local/bin ] || [ "${SUDO:-}" != "" ]; then
        curl -sL --retry 3 -o /tmp/ldid "$LDID_URL"
        chmod +x /tmp/ldid
        $SUDO mv /tmp/ldid /usr/local/bin/ldid 2>/dev/null || mv /tmp/ldid "$THEOS_DIR/bin/ldid"
    else
        curl -sL --retry 3 -o "$THEOS_DIR/bin/ldid" "$LDID_URL"
        chmod +x "$THEOS_DIR/bin/ldid"
    fi
fi
PATH="$THEOS_DIR/bin:/usr/local/bin:$PATH"
command -v ldid >/dev/null 2>&1 && ldid -V || echo "(!) ldid chưa có trong PATH — theos vẫn ký được bằng bản nội bộ"

# ----------------------------------------------------------------------------
# 5. Kiểm tra
# ----------------------------------------------------------------------------
log "Kiểm tra môi trường"
"$THEOS_DIR/toolchain/linux/iphone/bin/clang" --version | head -1
echo "  THEOS      = $THEOS_DIR"
ls "$THEOS_DIR/sdks/" | sed 's/^/  SDK        = /'
dpkg-deb --version 2>/dev/null | head -1 | sed 's/^/  /' || true
log "Môi trường build sẵn sàng. Dùng: export THEOS=$THEOS_DIR && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless"
