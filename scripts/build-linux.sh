#!/usr/bin/env bash
#
# build-linux.sh — Compile an LGPL-only FFmpeg for Linux (Docker).
#
# Usage:
#   scripts/build-linux.sh --target x86_64-unknown-linux-gnu
#
# Unlike the macOS and Windows builds, this binary is NOT self-contained: it
# runs inside the Polycast Docker image, which provides the external libraries
# (gnutls, libva, libopenh264) via apt. So FFmpeg's own libraries are static
# (--enable-static), but the external deps link dynamically against the image's
# shared objects — the standard, and for VAAPI the only practical, approach in a
# container. Build dependencies are installed by the CI workflow (see
# .github/workflows/build.yml); this script verifies they're present, then
# builds, verifies the LGPL discipline, and packages.
#
# Encoders: h264_nvenc (NVIDIA, runtime lib injected by the NVIDIA Container
# Toolkit), h264_vaapi (Intel iGPU + AMD via libva), libopenh264 (BSD-2-Clause
# CPU fallback), and native aac. QSV/oneVPL is intentionally omitted for V1 —
# VAAPI already covers Intel iGPUs; libvpl can be added later as a fast-follow.
#
# TLS for rtmps egress uses gnutls (LGPLv2.1+), so destinations that publish
# over rtmps:// work — the Linux equivalent of macOS securetransport / Windows
# schannel.
#
# Outputs:
#   dist/<triple>/
#     ffmpeg
#     ffprobe
#     COPYING.LGPLv2.1
#     SOURCE.txt
#     ffmpeg-<version>-<triple>.tar.gz
#     ffmpeg-<version>-<triple>.tar.gz.sha256
#
# Idempotent: caches the tarball and the unpacked source tree. Remove build/
# for a clean rebuild.
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
            echo "usage: $0 --target x86_64-unknown-linux-gnu" >&2
            exit 2
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "missing required --target flag" >&2
    echo "usage: $0 --target x86_64-unknown-linux-gnu" >&2
    exit 2
fi

# HW_ACCEL gates the GPU encoders. x86_64 servers get NVENC (NVIDIA) + VAAPI
# (Intel/AMD); arm64 servers have neither in practice (Ampere/Graviton have no
# GPU), so that build is software-encode + passthrough only — libopenh264 + aac,
# the same gnutls TLS for rtmps egress. Each target builds NATIVELY on its own
# arch (no cross-compilation); the CI matrix maps target → matching-arch runner.
case "$TARGET" in
    x86_64-unknown-linux-gnu)
        FFMPEG_ARCH="x86_64"
        HW_ACCEL="yes"
        ;;
    aarch64-unknown-linux-gnu)
        FFMPEG_ARCH="aarch64"
        HW_ACCEL="no"
        ;;
    *)
        echo "unsupported target: $TARGET" >&2
        echo "usage: $0 --target <x86_64|aarch64>-unknown-linux-gnu" >&2
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

# Defense-in-depth: VERSION drives the URL, but the source SHA256 is pinned.
# Bumping VERSION without updating this table aborts the build.
case "$FFMPEG_VERSION" in
    8.1.1) SHA256="b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3" ;;
    *)
        echo "✗ no pinned SHA256 for FFmpeg $FFMPEG_VERSION in scripts/build-linux.sh" >&2
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
# Native build: the runner's arch must match the target. uname -m reports
# x86_64 / aarch64, which is exactly FFMPEG_ARCH.
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "$FFMPEG_ARCH" ]; then
    echo "✗ host must be Linux ${FFMPEG_ARCH} for target ${TARGET}; got $(uname -s)/$(uname -m)" >&2
    echo "  run on the matching-arch runner (see .github/workflows/build.yml)" >&2
    exit 1
fi

mkdir -p "$BUILD_ROOT" "$OUT_DIR" "$(dirname "$TARBALL")"

# ---- prereq verification ----------------------------------------------------
# nasm is x86 SIMD assembly only; arm64 uses the GNU assembler shipped with gcc.
REQUIRED_TOOLS="gcc make git pkg-config curl tar sha256sum strings ldd"
[ "$FFMPEG_ARCH" = "x86_64" ] && REQUIRED_TOOLS="${REQUIRED_TOOLS} nasm"
for tool in $REQUIRED_TOOLS; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "✗ $tool not found in PATH" >&2
        echo "  install the build deps; see .github/workflows/build.yml" >&2
        exit 1
    fi
done

# NVENC headers + VAAPI are x86_64-only here (arm64 ships software-encode). Pin
# nv-codec-headers (the NVENC/NVDEC API stubs) from source, exactly as the
# Windows build does. The header version sets the MINIMUM NVIDIA driver NVENC
# accepts at runtime; n11.1.5.3 maps to a Linux driver floor of 470.57.02
# (~mid-2021) while still carrying every NVENC feature Polycast's H.264 argv
# uses. Keep this in lockstep with build-windows.sh.
if [ "$HW_ACCEL" = "yes" ]; then
    NVCODEC_TAG="n11.1.5.3"
    NVCODEC_DIR="${BUILD_ROOT}/nv-codec-headers"
    if [ ! -d "$NVCODEC_DIR/.git" ]; then
        rm -rf "$NVCODEC_DIR"
        git clone --depth 1 --branch "$NVCODEC_TAG" \
            https://github.com/FFmpeg/nv-codec-headers.git "$NVCODEC_DIR"
    fi
    echo "▶ installing pinned nv-codec-headers ${NVCODEC_TAG} (min NVIDIA driver 470.57.02 Linux)"
    make -C "$NVCODEC_DIR" PREFIX="$PREFIX" install >/dev/null
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
fi

# External deps come from the distro (apt); confirm pkg-config sees each before
# we configure, so a missing -dev package fails here with a clear message rather
# than as an opaque configure error. arm64 needs only gnutls + openh264 (no GPU).
PC_DEPS="gnutls openh264"
[ "$HW_ACCEL" = "yes" ] && PC_DEPS="gnutls libva libva-drm ffnvcodec openh264"
for pcfile in $PC_DEPS; do
    if ! pkg-config --exists "$pcfile" 2>/dev/null; then
        echo "✗ pkg-config can't find $pcfile" >&2
        case "$pcfile" in
            ffnvcodec) echo "  the pinned nv-codec-headers ${NVCODEC_TAG} install above failed — check git clone + make" >&2 ;;
            gnutls)    echo "  install: apt-get install libgnutls28-dev" >&2 ;;
            libva|libva-drm) echo "  install: apt-get install libva-dev" >&2 ;;
            openh264)  echo "  install: apt-get install libopenh264-dev" >&2 ;;
        esac
        exit 1
    fi
done

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
    # Encoder + filter sets diverge by arch; everything else (license discipline,
    # static link, gnutls TLS, the mux/demux/protocol set) is shared.
    #   --disable-gpl / --nonfree / --version3 / --autodetect
    #                              license discipline + no surprise deps
    #   --enable-static --disable-shared
    #                              FFmpeg's own libs static *into* the binary;
    #                              external deps (gnutls/va/openh264) link
    #                              dynamically against the image's shared objects.
    #   --enable-libopenh264       BSD-2-Clause CPU encoder. LGPL-clean.
    #   --enable-gnutls            (mac securetransport / win schannel → Linux
    #                              gnutls) TLS for rtmps:// egress. LGPLv2.1+.
    # x86_64 only (HW_ACCEL=yes):
    #   --enable-ffnvcodec/nvenc   NVIDIA NVENC; libnvidia-encode.so is dlopen'd +
    #                              injected by the NVIDIA Container Toolkit, so not
    #                              a build/image dep.
    #   --enable-vaapi             Intel iGPU + AMD via libva, plus the
    #                              hwupload/hwmap/scale_vaapi filters it needs.
    # arm64 omits all GPU paths — Ampere/Graviton have no encoder; it ships
    # passthrough + software (libopenh264) only. (QSV/oneVPL stays omitted on both
    # for V1.)
    HWACCEL_CONFIGURE=()
    ENCODERS="libopenh264,aac"
    EXTRA_FILTERS=""
    ACCEL_DESC="software (libopenh264) + passthrough only"
    if [ "$HW_ACCEL" = "yes" ]; then
        HWACCEL_CONFIGURE=(--enable-ffnvcodec --enable-nvenc --enable-vaapi)
        ENCODERS="h264_nvenc,hevc_nvenc,h264_vaapi,hevc_vaapi,libopenh264,aac"
        EXTRA_FILTERS=",hwupload,hwmap,scale_vaapi"
        ACCEL_DESC="NVENC + VAAPI + libopenh264 CPU fallback"
    fi

    echo "▶ configuring (LGPL only, ${ACCEL_DESC}, gnutls TLS) for ${TARGET}"
    ./configure \
        --prefix="$PREFIX" \
        --disable-gpl --disable-nonfree --disable-version3 \
        --disable-autodetect \
        --enable-static --disable-shared \
        --disable-programs --enable-ffmpeg --enable-ffprobe \
        --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
        --disable-debug \
        --enable-libopenh264 \
        --enable-gnutls \
        "${HWACCEL_CONFIGURE[@]}" \
        --enable-encoder="$ENCODERS" \
        --enable-decoder=h264,hevc,aac,mp3,pcm_s16le,pcm_s24le,pcm_f32le \
        --enable-muxer=flv,mp4,mov \
        --enable-demuxer=flv,mpegts,mov,mp4 \
        --enable-parser=h264,hevc,aac \
        --enable-protocol=rtmp,rtmps,tls,tcp,udp,file,pipe \
        --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb \
        --enable-filter="scale,fps,format,aresample,asetnsamples,anull,null,copy${EXTRA_FILTERS}" \
        --arch="$FFMPEG_ARCH" \
        --cc=gcc \
        --extra-cflags="-O3"
    touch "$STAMP"
else
    echo "✓ already configured (rm $STAMP to reconfigure)"
fi

# ---- build ------------------------------------------------------------------
echo "▶ building (this takes a few minutes)"
make -j"$(nproc)"
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

# Read the configuration string out of the binary directly — defence-in-depth
# even though we set the flags ourselves; catches an autodetect leak.
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

# This binary links external libs dynamically (it isn't self-contained), so the
# meaningful linkage check is the inverse of macOS's: confirm it does NOT pull in
# any GPL/non-free codec library. libva/gnutls/libopenh264/libc are expected.
DT_DEPS="$(ldd "$BIN" 2>/dev/null | awk '{print $1}')"
FORBIDDEN_LIBS="$(echo "$DT_DEPS" | grep -E 'libx264|libx265|libfdk|libav.*gpl' || true)"
if [ -n "$FORBIDDEN_LIBS" ]; then
    echo "✗ binary links a forbidden (GPL/non-free) library:" >&2
    echo "$FORBIDDEN_LIBS" >&2
    exit 1
fi
echo "  ✓ no GPL/non-free shared libraries in the link"

# Confirm each expected encoder ended up baked in (string-scan, no execution).
SYMS="$(strings "$BIN")"
NEEDED_ENCODERS=(libopenh264 'aac ')
[ "$HW_ACCEL" = "yes" ] && NEEDED_ENCODERS=(h264_nvenc h264_vaapi libopenh264 'aac ')
for needed in "${NEEDED_ENCODERS[@]}"; do
    case "$SYMS" in
        *"$needed"*) ;;
        *)
            echo "✗ binary missing expected symbol: $needed" >&2
            exit 1
            ;;
    esac
done
if [ "$HW_ACCEL" = "yes" ]; then
    echo "  ✓ nvenc + vaapi + libopenh264 + aac encoders present"
else
    echo "  ✓ libopenh264 + aac encoders present (software build)"
fi

# Native host: exercise both binaries end-to-end.
if ! "$BIN" -hide_banner -version >/dev/null; then
    echo "✗ ffmpeg -version failed" >&2
    exit 1
fi
if ! "$FFPROBE_BIN" -hide_banner -version >/dev/null; then
    echo "✗ ffprobe -version failed" >&2
    exit 1
fi
echo "  ✓ ffmpeg + ffprobe run"

# ---- rtmps throughput gate ----------------------------------------------------
# The regression this catches: a TLS backend whose handshake succeeds but whose
# sustained write path stalls (macOS SecureTransport shipped RTMPS at ~2% of
# real time for months because nothing measured throughput). Pushes 10s of
# 1080p60 at ~8 Mbps to a local MediaMTX over rtmps (self-signed cert) and
# requires the encode to hold >= 0.9x real time. A plain-rtmp control run first
# separates a TLS regression from an encoder/runner problem.
if ! command -v openssl >/dev/null 2>&1; then
    echo "✗ openssl not found (needed to generate the rtmps smoke-test cert)" >&2
    echo "  install: apt-get install -y openssl" >&2
    exit 1
fi
MEDIAMTX_VERSION="1.18.2"
case "$FFMPEG_ARCH" in
    x86_64)
        MEDIAMTX_ASSET="mediamtx_v${MEDIAMTX_VERSION}_linux_amd64.tar.gz"
        MEDIAMTX_SHA256="73ed27c292e05ceb4990dcb34531f01872dfff5374b7515c45a202e0abf47706"
        ;;
    aarch64)
        MEDIAMTX_ASSET="mediamtx_v${MEDIAMTX_VERSION}_linux_arm64.tar.gz"
        MEDIAMTX_SHA256="c78aa7a1bdab94b2b02be364661f17802143215dba37e1fa67c3e0849248b485"
        ;;
esac
MEDIAMTX_TARBALL="${REPO_ROOT}/build/${MEDIAMTX_ASSET}"
MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/${MEDIAMTX_ASSET}"
SMOKE_DIR="${BUILD_ROOT}/rtmps-smoke"

echo "▶ rtmps throughput gate"
if [ ! -f "$MEDIAMTX_TARBALL" ]; then
    curl -fL "$MEDIAMTX_URL" -o "$MEDIAMTX_TARBALL.partial"
    mv "$MEDIAMTX_TARBALL.partial" "$MEDIAMTX_TARBALL"
fi
MEDIAMTX_ACTUAL="$(sha256sum "$MEDIAMTX_TARBALL" | awk '{print $1}')"
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
        -c:v libopenh264 -b:v 8000k -maxrate 8000k -bufsize 8000k \
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

This binary links its external libraries (gnutls, libva, libopenh264) dynamically
against the libraries provided by the Polycast Docker image's distribution
packages; those libraries carry their own licenses (LGPL/BSD/MIT). Check out the
tag matching this binary's release to reproduce the build.
EOF

# ---- package ----------------------------------------------------------------
ARCHIVE="ffmpeg-${FFMPEG_VERSION}-${TARGET}.tar.gz"
echo "▶ packaging $ARCHIVE"
ARCHIVE_FILES=(ffmpeg ffprobe COPYING.LGPLv2.1 SOURCE.txt)
if [ -f "$OUT_DIR/FFMPEG-LICENSE.md" ]; then
    ARCHIVE_FILES+=(FFMPEG-LICENSE.md)
fi
( cd "$OUT_DIR" && tar -czf "$ARCHIVE" "${ARCHIVE_FILES[@]}" )
( cd "$OUT_DIR" && sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256" )

BIN_MB="$(awk "BEGIN{printf \"%.1f\", $(stat -c%s "$OUT_DIR/ffmpeg")/1024/1024}")"
PROBE_MB="$(awk "BEGIN{printf \"%.1f\", $(stat -c%s "$OUT_DIR/ffprobe")/1024/1024}")"

echo
echo "✅ LGPL ffmpeg ${FFMPEG_VERSION} built for ${TARGET}"
echo "   ffmpeg:   $OUT_DIR/ffmpeg   (${BIN_MB} MB)"
echo "   ffprobe:  $OUT_DIR/ffprobe  (${PROBE_MB} MB)"
echo "   archive:  $OUT_DIR/$ARCHIVE"
echo "   sha256:   $OUT_DIR/${ARCHIVE}.sha256"
