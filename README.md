# ffmpeg-lgpl-builds

Reproducible, LGPL-only FFmpeg binaries for closed-source applications.

Built and published by [@serversideup](https://github.com/serversideup) so that downstream projects can consume FFmpeg without inheriting GPL or non-free obligations. The primary consumer is [Polycast](https://github.com/serversideup/polycast), but the artifacts are usable by anyone who needs a redistributable FFmpeg under LGPL-2.1.

## What "LGPL-only" means here

The produced `ffmpeg` binary is configured with:

- `--disable-gpl` — no GPL-licensed code linked in (no `libx264`, no `libx265`, no `libxvid`, no `libpostproc`)
- `--disable-nonfree` — no non-free code (no `libfdk_aac`)
- `--disable-version3` — stays on LGPLv2.1 (avoids dependencies that would relicense the bundle to v3)
- `--disable-autodetect` — no Homebrew or system optional libs sneak in; only what we explicitly enable

The build is verified post-link to confirm none of those flags ended up enabled, and (on macOS) that the binary links only to system frameworks under `/System/` and `/usr/lib/`.

A consumer that bundles one of these binaries into a closed-source product still owes its end users the corresponding FFmpeg source under LGPL § 6. Since this repo's `VERSION` file pins an upstream FFmpeg release whose source is publicly available at `https://ffmpeg.org/releases/`, the source-availability obligation is satisfied by pointing users at that URL plus the SHA256 recorded in each release's `RELEASE-NOTES.md`. Consumers should reproduce this notice in their own distribution.

## How releases work

A release is cut whenever `VERSION` or the build script changes on `main` (or via manual `workflow_dispatch` for a one-off rebuild). The GitHub Actions workflow at `.github/workflows/build.yml` runs the platform-specific build script for every supported target, uploads the resulting binaries as a tagged release, and writes a `RELEASE-NOTES.md` recording the SHA256 of each artifact.

Tag format: `v<ffmpeg-version>-<run-number>`, e.g. `v8.1.1-42`, where `<run-number>` is the GitHub Actions workflow run number (monotonic, so every push or dispatch produces a fresh distinct tag — no counter file to keep in sync).

Per release, per target, the published artifacts are:

- `ffmpeg-<version>-<triple>.tar.gz` — contains the `ffmpeg` binary, `COPYING.LGPLv2.1`, and `SOURCE.txt` (provenance record)
- `ffmpeg-<version>-<triple>.tar.gz.sha256`

Currently supported targets:

- `aarch64-apple-darwin` (macOS, Apple Silicon)
- `x86_64-apple-darwin` (macOS, Intel — cross-compiled from Apple Silicon)

Planned (when downstream consumers need them):

- `x86_64-pc-windows-msvc`
- `x86_64-unknown-linux-gnu`

## How to bump the FFmpeg version

1. Look up the new upstream version at <https://ffmpeg.org/releases/>.
2. Verify the tarball's SHA256 against the upstream signed checksum file.
3. Edit `VERSION` to the new value, e.g. `8.2.0`.
4. Add a case branch for the new version to `scripts/build-macos.sh` with the pinned tarball SHA256 (defence-in-depth check).
5. Open a PR. CI runs the workflow on a draft tag for verification.
6. Merge to `main`. The push triggers the release workflow, producing `v<new-version>-<run-number>`.

## How to bump only the build flags

Edit `scripts/build-macos.sh` and merge to `main`. The push triggers a new release with the same `VERSION` and the next run number, e.g. `v8.1.1-43`. Release notes call out the flag delta.

## How to trigger an ad-hoc rebuild

Run the workflow manually from the Actions tab (`workflow_dispatch`). Produces a fresh tag at the next run number without any commit.

## How to verify a release independently

Given an artifact `ffmpeg-8.1.1-aarch64-apple-darwin.tar.gz`:

```bash
# Confirm the SHA256 matches the published .sha256
shasum -a 256 -c ffmpeg-8.1.1-aarch64-apple-darwin.tar.gz.sha256

# Confirm LGPL flags in the binary itself
tar -xzf ffmpeg-8.1.1-aarch64-apple-darwin.tar.gz
./ffmpeg -version | grep configuration | tr ' ' '\n' | grep -E '^--' | sort

# Should NOT contain: --enable-gpl, --enable-nonfree, --enable-version3
# Should contain: --disable-gpl, --disable-nonfree, --disable-version3
```

To reproduce from source, check out this repo at the tag and run `scripts/build-macos.sh --target aarch64-apple-darwin` on an Apple Silicon Mac with Xcode CLT installed. The resulting `dist/aarch64-apple-darwin/ffmpeg` should be bit-identical (modulo embedded timestamps).

## Licenses

- `LICENSE` — LGPL-2.1 text, applicable to the *produced FFmpeg binaries*
- `LICENSE-BUILD-SCRIPTS` — MIT, applicable to the build scripts in `scripts/` and the workflow files in `.github/`

In other words: this repo's *tooling* is liberally licensed (MIT) so you can adapt it for your own LGPL FFmpeg builds. The *output* of that tooling is LGPL because that's what FFmpeg itself is when configured this way.

## Related projects

- [serversideup/polycast](https://github.com/serversideup/polycast) — multi-streaming desktop app, primary consumer
