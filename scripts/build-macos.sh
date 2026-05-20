#!/usr/bin/env bash
#
# build-macos.sh — Compile an LGPL-only FFmpeg for macOS.
#
# Usage:
#   scripts/build-macos.sh --target aarch64-apple-darwin
#   scripts/build-macos.sh --target x86_64-apple-darwin
#
# Both targets must run on an Apple Silicon host. The x86_64 build is
# cross-compiled (clang on macOS can target either arch from either host
# given the right -arch flag plus FFmpeg's --enable-cross-compile).
#
# Produces a self-contained, statically-linked ffmpeg binary that links to
# only macOS system frameworks (no GPL libs, no Homebrew dylibs). Outputs:
#
#   dist/<triple>/
#     ffmpeg
#     COPYING.LGPLv2.1
#     SOURCE.txt
#     ffmpeg-<version>-<triple>.tar.gz
#     ffmpeg-<version>-<triple>.tar.gz.sha256
#
# Idempotent: caches the tarball and the unpacked source tree. Remove
# build/ for a clean rebuild.
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
            echo "usage: $0 --target {aarch64-apple-darwin|x86_64-apple-darwin}" >&2
            exit 2
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "missing required --target flag" >&2
    echo "usage: $0 --target {aarch64-apple-darwin|x86_64-apple-darwin}" >&2
    exit 2
fi

case "$TARGET" in
    aarch64-apple-darwin)
        FFMPEG_ARCH="arm64"
        CLANG_ARCH="arm64"
        CROSS=0
        ;;
    x86_64-apple-darwin)
        FFMPEG_ARCH="x86_64"
        CLANG_ARCH="x86_64"
        CROSS=1
        ;;
    *)
        echo "unsupported target: $TARGET" >&2
        exit 2
        ;;
esac

# ---- config -----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -f "$REPO_ROOT/VERSION" ]; then
    echo "missing $REPO_ROOT/VERSION" >&2
    exit 1
fi
FFMPEG_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"

# Defense-in-depth: even though VERSION drives the URL, the SHA256 is pinned
# here. Bumping VERSION without bumping this table aborts the build.
# (Case statement instead of an associative array so we stay compatible with
# macOS's stock bash 3.2.)
case "$FFMPEG_VERSION" in
    8.1.1) SHA256="b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3" ;;
    *)
        echo "✗ no pinned SHA256 for FFmpeg $FFMPEG_VERSION in scripts/build-macos.sh" >&2
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

# ---- host check -------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "✗ host must be macOS arm64; got $(uname -s)/$(uname -m)" >&2
    exit 1
fi

mkdir -p "$BUILD_ROOT" "$OUT_DIR" "$(dirname "$TARBALL")"

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
ACTUAL_SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
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

for tool in make clang; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "✗ $tool not found in PATH (need Xcode CLT: xcode-select --install)" >&2
        exit 1
    fi
done

# x86_64 builds need nasm for FFmpeg's hand-optimized x86 assembly. The arm64
# build doesn't need it (aarch64 asm is gas-syntax and goes through clang).
if [ "$CROSS" = "1" ] && ! command -v nasm >/dev/null 2>&1; then
    echo "✗ nasm not found in PATH (required for x86_64 hand-optimized asm)" >&2
    echo "  install: brew install nasm" >&2
    exit 1
fi

# Configure-stamp short-circuits reconfigure on repeat runs.
STAMP="${SOURCE_DIR}/.configured-for-${TARGET}"
if [ ! -f "$STAMP" ]; then
    echo "▶ configuring (LGPL only, VideoToolbox + native AAC) for ${TARGET}"
    # Flags rationale:
    #   --disable-gpl              never link GPL code (libx264, libx265, etc.)
    #   --disable-nonfree          never link non-free code (libfdk_aac, etc.)
    #   --disable-version3         keep us on LGPLv2.1, avoid v3-only deps
    #   --disable-autodetect       opt back in only to what we want; prevents
    #                              FFmpeg from baking /opt/homebrew paths in
    #   --enable-static / --disable-shared
    #                              one self-contained binary; no runtime dylibs
    #   --disable-programs --enable-ffmpeg
    #                              build the ffmpeg binary only
    #   --enable-videotoolbox      Apple hardware encoder/decoder framework
    #   --enable-audiotoolbox      Apple hardware audio framework
    #   --enable-securetransport   TLS for rtmps/https without OpenSSL
    EXTRA_CONFIGURE=()
    if [ "$CROSS" = "1" ]; then
        EXTRA_CONFIGURE+=(--enable-cross-compile)
    fi

    ./configure \
        --prefix="$PREFIX" \
        --disable-gpl --disable-nonfree --disable-version3 \
        --disable-autodetect \
        --enable-static --disable-shared \
        --disable-programs --enable-ffmpeg \
        --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
        --disable-debug \
        --enable-videotoolbox --enable-audiotoolbox \
        --enable-securetransport \
        --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac \
        --enable-decoder=h264,hevc,aac,mp3,pcm_s16le,pcm_s24le,pcm_f32le \
        --enable-muxer=flv,mp4,mov \
        --enable-demuxer=flv,mpegts,mov,mp4 \
        --enable-parser=h264,hevc,aac \
        --enable-protocol=rtmp,rtmps,tls,tcp,udp,file,pipe \
        --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb \
        --enable-filter=scale,fps,format,aresample,asetnsamples,anull,null,copy \
        --arch="$FFMPEG_ARCH" --target-os=darwin \
        --cc="clang -arch ${CLANG_ARCH}" \
        --extra-cflags="-arch ${CLANG_ARCH} -mmacosx-version-min=12.0 -O3" \
        --extra-ldflags="-arch ${CLANG_ARCH} -mmacosx-version-min=12.0" \
        ${EXTRA_CONFIGURE[@]+"${EXTRA_CONFIGURE[@]}"}
    touch "$STAMP"
else
    echo "✓ already configured (rm $STAMP to reconfigure)"
fi

# ---- build ------------------------------------------------------------------
echo "▶ building (this takes 1–3 min on M-series)"
make -j"$(sysctl -n hw.ncpu)"
make install

BIN="${PREFIX}/bin/ffmpeg"
if [ ! -x "$BIN" ]; then
    echo "✗ build did not produce $BIN" >&2
    exit 1
fi

# ---- verify the binary ------------------------------------------------------
echo "▶ verifying binary"

# Mach-O arch check works regardless of host/target arch.
ACTUAL_ARCH="$(lipo -archs "$BIN" 2>/dev/null || file "$BIN")"
case "$ACTUAL_ARCH" in
    *"$CLANG_ARCH"*)
        echo "  ✓ binary is ${CLANG_ARCH}"
        ;;
    *)
        echo "✗ binary arch mismatch: expected ${CLANG_ARCH}, got '$ACTUAL_ARCH'" >&2
        exit 1
        ;;
esac

# Confirm only macOS system libs are linked (works in either direction on arm64
# host inspecting an x86_64 Mach-O).
DEPS="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}')"
NON_SYSTEM="$(echo "$DEPS" | grep -Ev '^(/System/|/usr/lib/)' || true)"
if [ -n "$NON_SYSTEM" ]; then
    echo "✗ binary links to non-system libraries:" >&2
    echo "$NON_SYSTEM" >&2
    exit 1
fi
echo "  ✓ links only to macOS system frameworks"

# Read the configuration string out of the binary directly. This works for
# both native and cross-built binaries because the configure flags are baked
# in as a literal string in the .data section (no need to execute the binary).
CONFIG_LINE="$(strings "$BIN" | grep -E 'configuration:.*--disable-gpl' || true)"
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

# Confirm encoders we depend on (string-scan, no execution needed).
# Capture strings output once and pattern-match without piping into grep -q.
# (grep -q exits early on match, which causes strings to die on EPIPE; with
# `set -o pipefail` the whole pipeline then looks like a failure.)
SYMS="$(strings "$BIN")"
for needed in 'h264_videotoolbox' 'hevc_videotoolbox' 'aac '; do
    case "$SYMS" in
        *"$needed"*) ;;
        *)
            echo "✗ binary missing expected symbol: $needed" >&2
            exit 1
            ;;
    esac
done
echo "  ✓ videotoolbox + native aac encoders present"

# Native target: also exercise the binary end-to-end as belt+suspenders.
if [ "$CROSS" = "0" ]; then
    if ! "$BIN" -hide_banner -version >/dev/null; then
        echo "✗ ffmpeg -version failed on native build" >&2
        exit 1
    fi
    echo "  ✓ binary runs natively"
fi

# ---- stage ------------------------------------------------------------------
echo "▶ staging to $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp "$BIN" "$OUT_DIR/ffmpeg"
chmod +x "$OUT_DIR/ffmpeg"

cp "$SOURCE_DIR/COPYING.LGPLv2.1" "$OUT_DIR/COPYING.LGPLv2.1"
[ -f "$SOURCE_DIR/LICENSE.md" ] && cp "$SOURCE_DIR/LICENSE.md" "$OUT_DIR/FFMPEG-LICENSE.md"

CONFIG_CLEAN="$(echo "$CONFIG_LINE" | sed -E 's/^.*configuration:[[:space:]]*//')"

cat > "$OUT_DIR/SOURCE.txt" <<EOF
FFmpeg ${FFMPEG_VERSION}
Source tarball: ${TARBALL_URL}
SHA256:         ${SHA256}
Built on:       $(date -u +%Y-%m-%dT%H:%M:%SZ)
Built for:      ${TARGET}
Configuration:  ${CONFIG_CLEAN}

This binary is LGPL-2.1-only. Per LGPL § 6, downstream end users are entitled
to the complete corresponding source code for this FFmpeg build. The source
is available verbatim at the URL above (matching the SHA256). The build
scripts used to produce this binary are at:

  https://github.com/serversideup/ffmpeg-lgpl-builds

Check out the tag matching this binary's release to reproduce the build.
EOF

# ---- package ----------------------------------------------------------------
ARCHIVE="ffmpeg-${FFMPEG_VERSION}-${TARGET}.tar.gz"
echo "▶ packaging $ARCHIVE"
ARCHIVE_FILES=(ffmpeg COPYING.LGPLv2.1 SOURCE.txt)
if [ -f "$OUT_DIR/FFMPEG-LICENSE.md" ]; then
    ARCHIVE_FILES+=(FFMPEG-LICENSE.md)
fi
( cd "$OUT_DIR" && tar -czf "$ARCHIVE" "${ARCHIVE_FILES[@]}" )

# SHA256 of the tarball, plain text (one line, matches `shasum -a 256` format
# so `shasum -a 256 -c <file>.sha256` works).
( cd "$OUT_DIR" && shasum -a 256 "$ARCHIVE" > "${ARCHIVE}.sha256" )

BIN_SIZE="$(stat -f%z "$OUT_DIR/ffmpeg")"
BIN_MB="$(awk "BEGIN{printf \"%.1f\", $BIN_SIZE/1024/1024}")"

echo
echo "✅ LGPL ffmpeg ${FFMPEG_VERSION} built for ${TARGET}"
echo "   binary:   $OUT_DIR/ffmpeg  (${BIN_MB} MB)"
echo "   archive:  $OUT_DIR/$ARCHIVE"
echo "   sha256:   $OUT_DIR/${ARCHIVE}.sha256"
