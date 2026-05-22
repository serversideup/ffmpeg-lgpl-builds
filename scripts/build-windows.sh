#!/usr/bin/env bash
#
# build-windows.sh — Compile an LGPL-only FFmpeg for Windows.
#
# Run inside an MSYS2 MINGW64 shell with the toolchain + encoder header
# packages installed (see .github/workflows/build.yml for the package list).
#
# Usage:
#   scripts/build-windows.sh --target x86_64-pc-windows-msvc
#
# Produces self-contained ffmpeg.exe + ffprobe.exe binaries plus Intel's
# oneVPL dispatcher DLL (libvpl-2.dll), bundled in a tarball at:
#
#   dist/x86_64-pc-windows-msvc/
#     ffmpeg.exe
#     ffprobe.exe
#     libvpl-2.dll                          (Intel QSV dispatcher — ships with us)
#     COPYING.LGPLv2.1
#     LIBVPL-LICENSE.txt
#     SOURCE.txt
#     ffmpeg-<version>-<triple>.tar.gz
#     ffmpeg-<version>-<triple>.tar.gz.sha256
#
# Builds with mingw-w64 gcc even though the triple says "msvc" — the triple
# is a consumer convention (Rust, vendor.toml) for "Windows x64"; the
# resulting PE executable is ABI-identical from a subprocess caller's view.
# SOURCE.txt records the actual toolchain used so there's no ambiguity.
#
# Idempotent: caches the source tarball and the unpacked tree under build/.
# Remove build/ for a clean rebuild.
#
set -euo pipefail

# ---- args -------------------------------------------------------------------
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            TARGET="$2"
            shift 2
            ;;
        *)
            echo "unknown arg: $1" >&2
            echo "usage: $0 --target x86_64-pc-windows-msvc" >&2
            exit 2
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "missing required --target flag" >&2
    echo "usage: $0 --target x86_64-pc-windows-msvc" >&2
    exit 2
fi

case "$TARGET" in
    x86_64-pc-windows-msvc) ;;
    *)
        echo "unsupported target: $TARGET" >&2
        echo "currently only x86_64-pc-windows-msvc is supported" >&2
        exit 2
        ;;
esac

# ---- environment check ------------------------------------------------------
# Must run inside MSYS2's MINGW64 shell so PATH points at mingw gcc, not the
# msys-gcc (which would emit binaries linked against the MSYS2 POSIX runtime).
if [ "${MSYSTEM:-}" != "MINGW64" ]; then
    echo "✗ this script must run inside an MSYS2 MINGW64 shell (got MSYSTEM=${MSYSTEM:-unset})" >&2
    exit 1
fi

# ---- config -----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -f "$REPO_ROOT/VERSION" ]; then
    echo "missing $REPO_ROOT/VERSION" >&2
    exit 1
fi
FFMPEG_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"

# Defence-in-depth: pinned tarball SHA256, mirrored from scripts/build-macos.sh.
# Bumping VERSION without adding a branch here aborts the build.
case "$FFMPEG_VERSION" in
    8.1.1) SHA256="b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3" ;;
    *)
        echo "✗ no pinned SHA256 for FFmpeg $FFMPEG_VERSION in scripts/build-windows.sh" >&2
        echo "  add a case branch after verifying against ffmpeg.org" >&2
        exit 1
        ;;
esac

BUILD_ROOT="${REPO_ROOT}/build/${TARGET}"
TARBALL="${REPO_ROOT}/build/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SOURCE_DIR="${BUILD_ROOT}/ffmpeg-${FFMPEG_VERSION}"
PREFIX="${BUILD_ROOT}/install"
TARBALL_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
OUT_DIR="${REPO_ROOT}/dist/${TARGET}"

mkdir -p "$BUILD_ROOT" "$OUT_DIR" "$(dirname "$TARBALL")"

# ---- prereq verification ----------------------------------------------------
# Anchor pkg-config to the MINGW64 install so neither this script's checks
# nor FFmpeg's configure can pick up the msys2-native pkg-config (which
# wouldn't see /mingw64/lib/pkgconfig/) if PATH order ever shifted.
export PKG_CONFIG=/mingw64/bin/pkg-config
export PKG_CONFIG_PATH=/mingw64/lib/pkgconfig:/mingw64/share/pkgconfig

for tool in gcc make nasm "$PKG_CONFIG" curl tar sha256sum strings objdump; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "✗ $tool not found in PATH" >&2
        echo "  install MSYS2 MINGW64 toolchain + dependencies; see .github/workflows/build.yml" >&2
        exit 1
    fi
done

# Encoder header packages. NVENC + libvpl ship pkg-config files; AMF is
# header-only and detected by a path probe.
for pcfile in ffnvcodec vpl; do
    if ! "$PKG_CONFIG" --exists "$pcfile" 2>/dev/null; then
        echo "✗ pkg-config can't find $pcfile" >&2
        case "$pcfile" in
            ffnvcodec) echo "  install: pacman -S mingw-w64-x86_64-ffnvcodec-headers" >&2 ;;
            vpl)       echo "  install: pacman -S mingw-w64-x86_64-libvpl" >&2 ;;
        esac
        exit 1
    fi
done
if [ ! -f /mingw64/include/AMF/core/Factory.h ]; then
    echo "✗ AMF headers not found at /mingw64/include/AMF/" >&2
    echo "  install: pacman -S mingw-w64-x86_64-amf-headers" >&2
    exit 1
fi

# ---- fetch ------------------------------------------------------------------
if [ ! -f "$TARBALL" ]; then
    echo "▶ downloading ffmpeg ${FFMPEG_VERSION} source"
    curl -fL "$TARBALL_URL" -o "$TARBALL.partial"
    mv "$TARBALL.partial" "$TARBALL"
else
    echo "✓ tarball cached at $TARBALL"
fi

# ---- verify -----------------------------------------------------------------
echo "▶ verifying checksum"
ACTUAL_SHA256="$(sha256sum "$TARBALL" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$SHA256" ]; then
    echo "✗ checksum mismatch for $TARBALL" >&2
    echo "   expected: $SHA256" >&2
    echo "   actual:   $ACTUAL_SHA256" >&2
    exit 1
fi
echo "  ✓ sha256 ok"

# ---- extract ----------------------------------------------------------------
if [ ! -d "$SOURCE_DIR" ]; then
    echo "▶ extracting"
    tar -xf "$TARBALL" -C "$BUILD_ROOT"
else
    echo "✓ source tree present at $SOURCE_DIR"
fi

# ---- configure --------------------------------------------------------------
cd "$SOURCE_DIR"

STAMP="${SOURCE_DIR}/.configured-for-${TARGET}"
if [ ! -f "$STAMP" ]; then
    echo "▶ configuring (LGPL only, NVENC + QSV + AMF, Schannel TLS) for ${TARGET}"
    # Flag rationale (deltas from build-macos.sh in parens):
    #   --disable-gpl / --nonfree / --version3 / --autodetect
    #                              same — license discipline + no surprise deps
    #   --enable-static / --disable-shared
    #                              same — one self-contained binary
    #   --disable-programs --enable-ffmpeg --enable-ffprobe
    #                              same — ship the two CLI tools
    #   --enable-ffnvcodec         the NVIDIA codec headers library. Must be
    #                              named explicitly because --disable-autodetect
    #                              blocks the implicit auto-enable that nvenc
    #                              would otherwise pull in.
    #   --enable-nvenc             (mac h264_videotoolbox → Windows NVIDIA NVENC)
    #   --enable-amf               (… AMD AMF on Polaris+/Ryzen APUs)
    #   --enable-libvpl            (… Intel QSV via oneVPL dispatcher)
    #   --enable-schannel          (mac --enable-securetransport → Windows Schannel)
    #   --target-os=mingw32        FFmpeg's identifier for the mingw-w64 target
    #                              regardless of bitness (legacy naming)
    #   --pkg-config=$PKG_CONFIG   pin the MINGW64 pkg-config explicitly so the
    #                              cross-compile heuristic in FFmpeg's configure
    #                              can't pick up the msys2-native one
    #   --pkg-config-flags=--static
    #                              ask pkg-config for the static dep chain so
    #                              transitive libs (e.g. libvpl's deps) link
    #                              correctly
    #   --extra-ldflags="-static-libgcc -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic"
    #                              statically link mingw runtime pieces
    #                              (libgcc + libwinpthread) so the only DLL
    #                              we ship beside ffmpeg.exe is libvpl-2.dll
    ./configure \
        --prefix="$PREFIX" \
        --disable-gpl --disable-nonfree --disable-version3 \
        --disable-autodetect \
        --enable-static --disable-shared \
        --disable-programs --enable-ffmpeg --enable-ffprobe \
        --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
        --disable-debug \
        --enable-ffnvcodec \
        --enable-nvenc \
        --enable-amf \
        --enable-libvpl \
        --enable-schannel \
        --enable-encoder=h264_nvenc,hevc_nvenc,h264_amf,hevc_amf,h264_qsv,hevc_qsv,aac \
        --enable-decoder=h264,hevc,aac,mp3,pcm_s16le,pcm_s24le,pcm_f32le \
        --enable-muxer=flv,mp4,mov \
        --enable-demuxer=flv,mpegts,mov,mp4 \
        --enable-parser=h264,hevc,aac \
        --enable-protocol=rtmp,rtmps,tls,tcp,udp,file,pipe \
        --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb \
        --enable-filter=scale,fps,format,aresample,asetnsamples,anull,null,copy \
        --arch=x86_64 --target-os=mingw32 \
        --cc=gcc \
        --pkg-config="$PKG_CONFIG" \
        --pkg-config-flags=--static \
        --extra-cflags="-O3" \
        --extra-ldflags="-static-libgcc -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic"
    touch "$STAMP"
else
    echo "✓ already configured (rm $STAMP to reconfigure)"
fi

# ---- build ------------------------------------------------------------------
echo "▶ building (this takes a few minutes)"
make -j"$(nproc)"
make install

BIN="${PREFIX}/bin/ffmpeg.exe"
FFPROBE_BIN="${PREFIX}/bin/ffprobe.exe"
if [ ! -x "$BIN" ]; then
    echo "✗ build did not produce $BIN" >&2
    exit 1
fi
if [ ! -x "$FFPROBE_BIN" ]; then
    echo "✗ build did not produce $FFPROBE_BIN" >&2
    exit 1
fi

# ---- verify the binary ------------------------------------------------------
echo "▶ verifying binary"

# Read the configuration string out of the binary directly. Defence-in-depth
# even though we set the flags ourselves — catches an autodetect leak.
CONFIG_LINE="$(strings "$BIN" | grep -E 'configuration:.*--disable-gpl' | head -n1 || true)"
if [ -z "$CONFIG_LINE" ]; then
    echo "✗ couldn't find embedded configuration string in $BIN" >&2
    exit 1
fi
for forbidden in '--enable-gpl' '--enable-nonfree' '--enable-version3'; do
    if echo "$CONFIG_LINE" | grep -q -- "$forbidden"; then
        echo "✗ binary has $forbidden — refusing to ship" >&2
        echo "   $CONFIG_LINE" >&2
        exit 1
    fi
done
echo "  ✓ no GPL / non-free / v3 flags"

# Confirm each expected encoder ended up baked in. Same string-scan pattern
# as build-macos.sh; captures `strings` output once to avoid pipefail / EPIPE
# when grep -q would close the pipe early.
SYMS="$(strings "$BIN")"
for needed in 'h264_nvenc' 'hevc_nvenc' 'h264_amf' 'hevc_amf' 'h264_qsv' 'hevc_qsv' 'aac '; do
    case "$SYMS" in
        *"$needed"*) ;;
        *)
            echo "✗ binary missing expected symbol: $needed" >&2
            exit 1
            ;;
    esac
done
echo "  ✓ nvenc + amf + qsv + aac encoders present"

# DLL import audit. Anything outside this allow-list means a mingw runtime
# DLL leaked (libgcc_s_*, libwinpthread, libssp) or --disable-autodetect
# missed a transitive — either way we refuse to ship.
ALLOWED=(
    KERNEL32.dll USER32.dll GDI32.dll ADVAPI32.dll SHELL32.dll
    OLE32.dll OLEAUT32.dll WS2_32.dll IPHLPAPI.dll
    BCRYPT.dll SECUR32.dll CRYPT32.dll NCRYPT.dll
    msvcrt.dll
    libvpl-2.dll
)
verify_imports() {
    local exe="$1"
    local label="$2"
    local dll
    while read -r dll; do
        dll="$(echo "$dll" | tr -d '[:space:]')"
        [ -z "$dll" ] && continue
        local ok=0
        for allowed in "${ALLOWED[@]}"; do
            if [ "${dll,,}" = "${allowed,,}" ]; then ok=1; break; fi
        done
        if [ "$ok" -eq 0 ]; then
            echo "✗ $label depends on unexpected DLL: $dll" >&2
            return 1
        fi
    done < <(objdump -p "$exe" | grep -i 'DLL Name:' | awk '{print $3}')
}
verify_imports "$BIN"         "ffmpeg.exe"
verify_imports "$FFPROBE_BIN"  "ffprobe.exe"
echo "  ✓ imports only allowed Windows DLLs + libvpl"

# Native run check — we're on Windows, so we can just execute the binary.
if ! "$BIN" -hide_banner -version >/dev/null; then
    echo "✗ ffmpeg -version failed" >&2
    exit 1
fi
if ! "$FFPROBE_BIN" -hide_banner -version >/dev/null; then
    echo "✗ ffprobe -version failed" >&2
    exit 1
fi
echo "  ✓ binaries run"

# ---- stage ------------------------------------------------------------------
echo "▶ staging to $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp "$BIN" "$OUT_DIR/ffmpeg.exe"
cp "$FFPROBE_BIN" "$OUT_DIR/ffprobe.exe"

# Bundle Intel's oneVPL dispatcher. ffmpeg.exe imports it for QSV encoding;
# there's no static option for the dispatcher (that's the dispatcher's whole
# job — selecting the right vendor runtime at load time).
VPL_DLL="/mingw64/bin/libvpl-2.dll"
if [ ! -f "$VPL_DLL" ]; then
    echo "✗ libvpl-2.dll not found at $VPL_DLL" >&2
    exit 1
fi
cp "$VPL_DLL" "$OUT_DIR/libvpl-2.dll"

cp "$SOURCE_DIR/COPYING.LGPLv2.1" "$OUT_DIR/COPYING.LGPLv2.1"

# Bundle libvpl's license alongside the DLL we ship (MIT).
for vpl_license in /mingw64/share/licenses/libvpl/LICENSE.txt /mingw64/share/licenses/libvpl/LICENSE; do
    if [ -f "$vpl_license" ]; then
        cp "$vpl_license" "$OUT_DIR/LIBVPL-LICENSE.txt"
        break
    fi
done

CONFIG_CLEAN="$(echo "$CONFIG_LINE" | sed -E 's/^.*configuration:[[:space:]]*//')"

cat > "$OUT_DIR/SOURCE.txt" <<EOF
FFmpeg ${FFMPEG_VERSION}
Source tarball: ${TARBALL_URL}
SHA256:         ${SHA256}
Built on:       $(date -u +%Y-%m-%dT%H:%M:%SZ)
Built for:      ${TARGET}
Toolchain:      mingw-w64 gcc (via MSYS2)
Configuration:  ${CONFIG_CLEAN}

This binary is LGPL-2.1-only. Per LGPL § 6, downstream end users are entitled
to the complete corresponding source code for this FFmpeg build. The source
is available verbatim at the URL above (matching the SHA256). The build
scripts used to produce this binary are at:

  https://github.com/serversideup/ffmpeg-lgpl-builds

Check out the tag matching this binary's release to reproduce the build.

This artifact also bundles libvpl-2.dll, Intel's oneVPL dispatcher (MIT-
licensed). It is loaded by ffmpeg.exe at runtime when the Intel Quick Sync
encoders (h264_qsv / hevc_qsv) are selected. See LIBVPL-LICENSE.txt for the
dispatcher's license terms.

The "msvc" in the target triple is a consumer convention (Rust, vendor.toml)
for "Windows x64." The actual build toolchain is mingw-w64 gcc; the resulting
.exe is a standard Windows PE executable and behaves identically regardless
of the consumer's chosen toolchain.
EOF

# ---- package ----------------------------------------------------------------
ARCHIVE="ffmpeg-${FFMPEG_VERSION}-${TARGET}.tar.gz"
echo "▶ packaging $ARCHIVE"
ARCHIVE_FILES=(ffmpeg.exe ffprobe.exe libvpl-2.dll COPYING.LGPLv2.1 SOURCE.txt)
if [ -f "$OUT_DIR/LIBVPL-LICENSE.txt" ]; then
    ARCHIVE_FILES+=(LIBVPL-LICENSE.txt)
fi
( cd "$OUT_DIR" && tar -czf "$ARCHIVE" "${ARCHIVE_FILES[@]}" )
( cd "$OUT_DIR" && sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256" )

BIN_SIZE="$(stat -c%s "$OUT_DIR/ffmpeg.exe")"
BIN_MB="$(awk "BEGIN{printf \"%.1f\", $BIN_SIZE/1024/1024}")"
PROBE_SIZE="$(stat -c%s "$OUT_DIR/ffprobe.exe")"
PROBE_MB="$(awk "BEGIN{printf \"%.1f\", $PROBE_SIZE/1024/1024}")"
VPL_SIZE="$(stat -c%s "$OUT_DIR/libvpl-2.dll")"
VPL_KB="$(awk "BEGIN{printf \"%.0f\", $VPL_SIZE/1024}")"

echo
echo "✅ LGPL ffmpeg ${FFMPEG_VERSION} built for ${TARGET}"
echo "   ffmpeg:    $OUT_DIR/ffmpeg.exe    (${BIN_MB} MB)"
echo "   ffprobe:   $OUT_DIR/ffprobe.exe   (${PROBE_MB} MB)"
echo "   libvpl-2:  $OUT_DIR/libvpl-2.dll  (${VPL_KB} KB — Intel QSV dispatcher)"
echo "   archive:   $OUT_DIR/$ARCHIVE"
echo "   sha256:    $OUT_DIR/${ARCHIVE}.sha256"
