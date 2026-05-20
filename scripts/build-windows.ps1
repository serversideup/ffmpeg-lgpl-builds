# build-windows.ps1 — placeholder for Windows LGPL FFmpeg builds.
#
# Not yet implemented. Will produce x86_64-pc-windows-msvc artifacts that
# match the contract documented in README.md once Polycast (or another
# consumer) starts targeting Windows.
#
# Expected approach when implemented:
#   - vcpkg or direct MSYS2/MinGW for build environment
#   - same --disable-gpl / --disable-nonfree / --disable-version3 flags
#   - hardware encoders: NVENC / AMF / QSV (all LGPL-clean — they're
#     SDK headers, not GPL libraries)
#   - same artifact layout: dist/x86_64-pc-windows-msvc/{ffmpeg.exe, COPYING.LGPLv2.1, SOURCE.txt}

Write-Error "build-windows.ps1 is not yet implemented. See README.md for the artifact contract."
exit 2
