#!/usr/bin/env bash
#
# build-linux.sh — placeholder for Linux LGPL FFmpeg builds.
#
# Not yet implemented. Will produce x86_64-unknown-linux-gnu artifacts that
# match the contract documented in README.md once Polycast's Docker deploy
# (or another consumer) needs them.
#
# Expected approach when implemented:
#   - run inside a pinned Debian/Ubuntu LTS container so glibc is predictable
#   - same --disable-gpl / --disable-nonfree / --disable-version3 flags
#   - same --disable-programs --enable-ffmpeg --enable-ffprobe selection
#   - hardware encoders: VAAPI / NVENC / QSV (all LGPL-clean)
#   - same artifact layout: dist/x86_64-unknown-linux-gnu/{ffmpeg, ffprobe, COPYING.LGPLv2.1, SOURCE.txt}
#
set -euo pipefail

echo "build-linux.sh is not yet implemented. See README.md for the artifact contract." >&2
exit 2
