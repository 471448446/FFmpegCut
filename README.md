# FFmpegCut

Corresponding FFmpeg source and build materials for the FFmpeg binaries
distributed with Compress.

This repository is not the Compress app source code. It exists to provide the
FFmpeg source, build scripts, license texts, and verification notes required for
the LGPL-covered FFmpeg component shipped in the app.

## Build Profile

- FFmpeg version: `n7.1.5`
- License: LGPL v2.1 or later
- Android NDK: `28.2.13676358`
- minSdk: `24`
- ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`
- Output: shared libraries (`libav*.so`)

The build intentionally does not enable:

- `--enable-gpl`
- `--enable-nonfree`
- `x264`
- `x265`
- `libfdk-aac`
- `libxvid`

No upstream FFmpeg source files are modified. The app uses a configure-level
feature subset only.

## Repository Contents

- `scripts/build_ffmpeg_android.sh`: Android cross-build script for the LGPL
  FFmpeg subset used by Compress.
- `scripts/verify_ffmpeg.sh`: verification script for required libraries,
  16 KB page-size alignment, and LGPL/GPL configure checks.
- `LICENSES/`: LGPL license texts shipped with the app.
- `patches/`: patch notes for upstream FFmpeg source changes.
- `configs/`: notes for per-ABI `config.log` files.

## Source Archive and Config Logs

The corresponding upstream FFmpeg source is available from the official FFmpeg
release archive:

- https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz

The source archive is intentionally not committed to this repository. If the
official archive becomes unavailable, publish the same source archive as a
GitHub Release asset for the matching app build.

Small build evidence files should be attached to the matching GitHub Release
when available:

- `arm64-v8a.config.log`
- `armeabi-v7a.config.log`
- `x86_64.config.log`
- `verify-output.txt`

Compiled binaries are intentionally not committed to Git.

## Build

```bash
FFMPEG_SRC=/path/to/ffmpeg \
NDK=/path/to/android-ndk-r28 \
INSTALL_ROOT=/tmp/compress-ffmpeg-out \
ABIS="arm64-v8a armeabi-v7a x86_64" \
bash scripts/build_ffmpeg_android.sh
```

## Verify

```bash
NDK=/path/to/android-ndk-r28 \
INSTALL_ROOT=/tmp/compress-ffmpeg-out \
bash scripts/verify_ffmpeg.sh
```

To verify configure licensing for a saved log:

```bash
bash scripts/verify_ffmpeg.sh --check-config configs/arm64-v8a.config.log
```

## Notes

The FFmpeg libraries are dynamically linked in the Android app. The app keeps
FFmpeg as an LGPL-only build by avoiding GPL and nonfree components.
