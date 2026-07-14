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
# Produces self-contained, statically-linked ffmpeg + ffprobe binaries that
# link to only macOS system frameworks (no GPL libs, no Homebrew dylibs).
# Outputs:
#
#   dist/<triple>/
#     ffmpeg
#     ffprobe
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
    8.1.2) SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c" ;;
    8.1.1) SHA256="b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3" ;;
    *)
        echo "✗ no pinned SHA256 for FFmpeg $FFMPEG_VERSION in scripts/build-macos.sh" >&2
        echo "  add a case branch after verifying against ffmpeg.org" >&2
        exit 1
        ;;
esac

# OpenSSL provides FFmpeg's TLS backend (--enable-openssl) for rtmps/https.
# Apache-2.0 — in none of FFmpeg's GPL/NONFREE/VERSION3 lists since FFmpeg
# relicensed its OpenSSL 3 handling (2023), so no banned flag is needed.
# Replaces SecureTransport, and NOT libtls/mbedtls, for measured reasons:
# RTMP probes its transport with nonblocking 1-byte reads (rtmpproto.c), and
# the securetransport + libtls backends turn that probe into a blocking read
# that waits for the server's next ack — RTMPS throughput collapses to ~2.5%
# of real time (identical 0.025x measured on both; openssl: 5.1x). mbedtls
# requires --enable-version3. Field- and bench-verified 2026-07; the rtmps
# throughput gate below keeps this from regressing. SHA256 from the official
# release's published .sha256 asset.
OPENSSL_VERSION="3.5.7"
OPENSSL_SHA256="a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"
OPENSSL_TARBALL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

BUILD_ROOT="${REPO_ROOT}/build/${TARGET}"
TARBALL="${REPO_ROOT}/build/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SOURCE_DIR="${BUILD_ROOT}/ffmpeg-${FFMPEG_VERSION}"
PREFIX="${BUILD_ROOT}/install"
TARBALL_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
OUT_DIR="${REPO_ROOT}/dist/${TARGET}"
OPENSSL_TARBALL="${REPO_ROOT}/build/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_SOURCE_DIR="${BUILD_ROOT}/openssl-${OPENSSL_VERSION}"
DEPS_PREFIX="${BUILD_ROOT}/deps"

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

# ---- openssl (TLS backend) ----------------------------------------------------
# pkg-config is how FFmpeg's configure discovers openssl (check_pkg_config).
if ! command -v pkg-config >/dev/null 2>&1; then
    echo "✗ pkg-config not found in PATH (required for --enable-openssl)" >&2
    echo "  install: brew install pkg-config" >&2
    exit 1
fi

if [ ! -f "$OPENSSL_TARBALL" ]; then
    echo "▶ downloading OpenSSL ${OPENSSL_VERSION} source"
    curl -fL "$OPENSSL_TARBALL_URL" -o "$OPENSSL_TARBALL.partial"
    mv "$OPENSSL_TARBALL.partial" "$OPENSSL_TARBALL"
else
    echo "✓ OpenSSL tarball cached at $OPENSSL_TARBALL"
fi

echo "▶ verifying OpenSSL checksum"
OPENSSL_ACTUAL_SHA256="$(shasum -a 256 "$OPENSSL_TARBALL" | awk '{print $1}')"
if [ "$OPENSSL_ACTUAL_SHA256" != "$OPENSSL_SHA256" ]; then
    echo "✗ checksum mismatch for $OPENSSL_TARBALL" >&2
    echo "   expected: $OPENSSL_SHA256" >&2
    echo "   actual:   $OPENSSL_ACTUAL_SHA256" >&2
    exit 1
fi
echo "  ✓ sha256 ok"

# Static-only install: FFmpeg links libssl/libcrypto .a files into the final
# binary, so the system-frameworks-only otool -L guard still holds.
if [ ! -f "$DEPS_PREFIX/lib/libssl.a" ]; then
    if [ ! -d "$OPENSSL_SOURCE_DIR" ]; then
        echo "▶ extracting OpenSSL"
        tar -xf "$OPENSSL_TARBALL" -C "$BUILD_ROOT"
    fi
    echo "▶ building OpenSSL ${OPENSSL_VERSION} (static) for ${TARGET} — takes a few minutes"
    OPENSSL_TARGET="darwin64-arm64-cc"
    if [ "$CROSS" = "1" ]; then
        OPENSSL_TARGET="darwin64-x86_64-cc"
    fi
    (
        cd "$OPENSSL_SOURCE_DIR"
        ./Configure "$OPENSSL_TARGET" \
            --prefix="$DEPS_PREFIX" --libdir=lib \
            no-shared no-tests no-docs no-apps \
            -mmacosx-version-min=12.0 \
            >/dev/null
        make -j"$(sysctl -n hw.ncpu)" >/dev/null 2>&1
        # install_sw = libs + headers + pkg-config files, no docs/scripts.
        make install_sw >/dev/null
    )
    echo "  ✓ OpenSSL installed to $DEPS_PREFIX"
else
    echo "✓ OpenSSL already built at $DEPS_PREFIX"
fi

export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig"

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
    #   --disable-programs --enable-ffmpeg --enable-ffprobe
    #                              ship ffmpeg + ffprobe; no ffplay (drags in SDL)
    #   --enable-videotoolbox      Apple hardware encoder/decoder framework
    #   --enable-audiotoolbox      Apple hardware audio framework
    #   --enable-openssl           TLS for rtmps/https via static OpenSSL 3.
    #                              NOT securetransport or libtls: both turn
    #                              RTMP's nonblocking server-message probe into
    #                              a blocking read, collapsing RTMPS throughput
    #                              to ~2.5% of real time (bench-verified
    #                              2026-07; openssl measured 5.1x on the same
    #                              case). Backends conflict; exactly one is set.
    EXTRA_CONFIGURE=()
    if [ "$CROSS" = "1" ]; then
        EXTRA_CONFIGURE+=(--enable-cross-compile)
    fi

    ./configure \
        --prefix="$PREFIX" \
        --disable-gpl --disable-nonfree --disable-version3 \
        --disable-autodetect \
        --enable-static --disable-shared \
        --disable-programs --enable-ffmpeg --enable-ffprobe \
        --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
        --disable-debug \
        --enable-videotoolbox --enable-audiotoolbox \
        --enable-openssl \
        --pkg-config-flags=--static \
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
FFPROBE_BIN="${PREFIX}/bin/ffprobe"
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

# TLS backend must be openssl — a build that silently dropped it would ship
# with rtmps/https broken, and securetransport/libtls stall RTMPS (see the
# configure comment above).
if ! echo "$CONFIG_LINE" | grep -q -- '--enable-openssl'; then
    echo "✗ binary built without --enable-openssl — rtmps/https would be broken" >&2
    exit 1
fi
for stalling in '--enable-securetransport' '--enable-libtls'; do
    if echo "$CONFIG_LINE" | grep -q -- "$stalling"; then
        echo "✗ binary has $stalling — that backend stalls RTMPS; refusing to ship" >&2
        exit 1
    fi
done
echo "  ✓ TLS backend is openssl"

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

# ffprobe sanity: same source build, same configure flags — so the LGPL/forbidden
# checks above cover both. We still verify arch and linkage on the ffprobe binary
# directly to catch a mispackaged dist (e.g. a stale install/ from a previous run).
PROBE_ARCH="$(lipo -archs "$FFPROBE_BIN" 2>/dev/null || file "$FFPROBE_BIN")"
case "$PROBE_ARCH" in
    *"$CLANG_ARCH"*)
        echo "  ✓ ffprobe is ${CLANG_ARCH}"
        ;;
    *)
        echo "✗ ffprobe arch mismatch: expected ${CLANG_ARCH}, got '$PROBE_ARCH'" >&2
        exit 1
        ;;
esac
PROBE_DEPS="$(otool -L "$FFPROBE_BIN" | tail -n +2 | awk '{print $1}')"
PROBE_NON_SYSTEM="$(echo "$PROBE_DEPS" | grep -Ev '^(/System/|/usr/lib/)' || true)"
if [ -n "$PROBE_NON_SYSTEM" ]; then
    echo "✗ ffprobe links to non-system libraries:" >&2
    echo "$PROBE_NON_SYSTEM" >&2
    exit 1
fi
echo "  ✓ ffprobe links only to macOS system frameworks"

if [ "$CROSS" = "0" ]; then
    if ! "$FFPROBE_BIN" -hide_banner -version >/dev/null; then
        echo "✗ ffprobe -version failed on native build" >&2
        exit 1
    fi
    echo "  ✓ ffprobe runs natively"
fi

# ---- rtmps throughput gate (native target only) -------------------------------
# The regression this catches: a TLS backend whose handshake succeeds but whose
# sustained write path stalls. SecureTransport shipped RTMPS at ~2% of real
# time for months because nothing measured throughput — a handshake-only test
# passes on a backend that is unusable for streaming. Pushes 10s of 1080p60 at
# ~8 Mbps to a local MediaMTX over rtmps (self-signed cert) and requires the
# encode to hold >= 0.9x real time. A plain-rtmp control run first separates a
# TLS regression from an encoder/runner problem.
if [ "$CROSS" = "0" ]; then
    MEDIAMTX_VERSION="1.18.2"
    MEDIAMTX_SHA256="6a9273ae22a9d0ba85d00d03fdd1b13b9eeaf129ea8b90999ec746367f20449a" # darwin_arm64
    MEDIAMTX_TARBALL="${REPO_ROOT}/build/mediamtx_v${MEDIAMTX_VERSION}_darwin_arm64.tar.gz"
    MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/mediamtx_v${MEDIAMTX_VERSION}_darwin_arm64.tar.gz"
    SMOKE_DIR="${BUILD_ROOT}/rtmps-smoke"

    echo "▶ rtmps throughput gate"
    if [ ! -f "$MEDIAMTX_TARBALL" ]; then
        curl -fL "$MEDIAMTX_URL" -o "$MEDIAMTX_TARBALL.partial"
        mv "$MEDIAMTX_TARBALL.partial" "$MEDIAMTX_TARBALL"
    fi
    MEDIAMTX_ACTUAL="$(shasum -a 256 "$MEDIAMTX_TARBALL" | awk '{print $1}')"
    if [ "$MEDIAMTX_ACTUAL" != "$MEDIAMTX_SHA256" ]; then
        echo "✗ checksum mismatch for $MEDIAMTX_TARBALL" >&2
        exit 1
    fi

    rm -rf "$SMOKE_DIR"
    mkdir -p "$SMOKE_DIR"
    tar -xf "$MEDIAMTX_TARBALL" -C "$SMOKE_DIR" mediamtx
    openssl req -x509 -newkey rsa:2048 -keyout "$SMOKE_DIR/key.pem" \
        -out "$SMOKE_DIR/cert.pem" -days 1 -nodes -subj "/CN=localhost" 2>/dev/null
    cat > "$SMOKE_DIR/mediamtx.yml" <<'SMOKEEOF'
logLevel: error
api: no
rtsp: no
hls: no
webrtc: no
srt: no
rtmp: yes
rtmpAddress: :13935
rtmpEncryption: optional
rtmpsAddress: :13936
rtmpServerCert: cert.pem
rtmpServerKey: key.pem
paths:
  smoke:
SMOKEEOF
    ( cd "$SMOKE_DIR" && ./mediamtx mediamtx.yml > mediamtx.log 2>&1 ) &
    MEDIAMTX_PID=$!
    trap 'kill $MEDIAMTX_PID 2>/dev/null || true' EXIT
    sleep 2

    smoke_push() { # $1 = output URL; echoes the final encode speed multiplier
        "$BIN" -hide_banner -loglevel warning -stats \
            -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 10 \
            -c:v h264_videotoolbox -allow_sw 1 -b:v 8000k -maxrate 8000k -bufsize 8000k \
            -f flv "$1" 2>&1 |
            grep -o 'speed= *[0-9.]*x' | tail -1 | grep -o '[0-9.]*'
    }

    RTMP_SPEED="$(smoke_push rtmp://127.0.0.1:13935/smoke || echo 0)"
    if ! awk "BEGIN{exit !($RTMP_SPEED >= 0.9)}"; then
        echo "✗ plain-rtmp control push ran at ${RTMP_SPEED:-0}x (< 0.9x) — runner/encoder problem, cannot evaluate TLS" >&2
        exit 1
    fi
    echo "  ✓ rtmp control: ${RTMP_SPEED}x"

    RTMPS_SPEED="$(smoke_push rtmps://127.0.0.1:13936/smoke || echo 0)"
    if ! awk "BEGIN{exit !($RTMPS_SPEED >= 0.9)}"; then
        echo "✗ rtmps push ran at ${RTMPS_SPEED:-0}x (< 0.9x) — TLS write path is stalling; refusing to ship" >&2
        exit 1
    fi
    echo "  ✓ rtmps throughput: ${RTMPS_SPEED}x"

    kill $MEDIAMTX_PID 2>/dev/null || true
    trap - EXIT
else
    echo "▶ rtmps throughput gate skipped (cross-built binary can't run on this host)"
fi

# ---- stage ------------------------------------------------------------------
echo "▶ staging to $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp "$BIN" "$OUT_DIR/ffmpeg"
chmod +x "$OUT_DIR/ffmpeg"
cp "$FFPROBE_BIN" "$OUT_DIR/ffprobe"
chmod +x "$OUT_DIR/ffprobe"

cp "$SOURCE_DIR/COPYING.LGPLv2.1" "$OUT_DIR/COPYING.LGPLv2.1"
[ -f "$SOURCE_DIR/LICENSE.md" ] && cp "$SOURCE_DIR/LICENSE.md" "$OUT_DIR/FFMPEG-LICENSE.md"
# OpenSSL is statically linked in; Apache-2.0 requires the notice to travel
# with it.
cp "$OPENSSL_SOURCE_DIR/LICENSE.txt" "$OUT_DIR/OPENSSL-LICENSE"

CONFIG_CLEAN="$(echo "$CONFIG_LINE" | sed -E 's/^.*configuration:[[:space:]]*//')"

cat > "$OUT_DIR/SOURCE.txt" <<EOF
FFmpeg ${FFMPEG_VERSION}
Source tarball: ${TARBALL_URL}
SHA256:         ${SHA256}
Built on:       $(date -u +%Y-%m-%dT%H:%M:%SZ)
Built for:      ${TARGET}
Configuration:  ${CONFIG_CLEAN}

Statically linked third-party libraries:
  OpenSSL ${OPENSSL_VERSION} (Apache-2.0 license, see OPENSSL-LICENSE)
  Source tarball: ${OPENSSL_TARBALL_URL}
  SHA256:         ${OPENSSL_SHA256}

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
ARCHIVE_FILES=(ffmpeg ffprobe COPYING.LGPLv2.1 SOURCE.txt OPENSSL-LICENSE)
if [ -f "$OUT_DIR/FFMPEG-LICENSE.md" ]; then
    ARCHIVE_FILES+=(FFMPEG-LICENSE.md)
fi
( cd "$OUT_DIR" && tar -czf "$ARCHIVE" "${ARCHIVE_FILES[@]}" )

# SHA256 of the tarball, plain text (one line, matches `shasum -a 256` format
# so `shasum -a 256 -c <file>.sha256` works).
( cd "$OUT_DIR" && shasum -a 256 "$ARCHIVE" > "${ARCHIVE}.sha256" )

BIN_SIZE="$(stat -f%z "$OUT_DIR/ffmpeg")"
BIN_MB="$(awk "BEGIN{printf \"%.1f\", $BIN_SIZE/1024/1024}")"
PROBE_SIZE="$(stat -f%z "$OUT_DIR/ffprobe")"
PROBE_MB="$(awk "BEGIN{printf \"%.1f\", $PROBE_SIZE/1024/1024}")"

echo
echo "✅ LGPL ffmpeg ${FFMPEG_VERSION} built for ${TARGET}"
echo "   ffmpeg:   $OUT_DIR/ffmpeg   (${BIN_MB} MB)"
echo "   ffprobe:  $OUT_DIR/ffprobe  (${PROBE_MB} MB)"
echo "   archive:  $OUT_DIR/$ARCHIVE"
echo "   sha256:   $OUT_DIR/${ARCHIVE}.sha256"
