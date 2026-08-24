# Configure Logs

Store per-ABI FFmpeg `ffbuild/config.log` files as GitHub Release assets for the
matching app release:

- `arm64-v8a.config.log`
- `armeabi-v7a.config.log`
- `x86_64.config.log`

These logs are useful for confirming the exact configure flags and checking that
the FFmpeg license line remains LGPL, with no `--enable-gpl` or
`--enable-nonfree`.

They cannot be reconstructed from already compiled `.so` files. Keep them from
the FFmpeg source tree immediately after each ABI build:

```bash
cp "$FFMPEG_SRC/ffbuild/config.log" configs/arm64-v8a.config.log
```

Repeat the copy after each ABI build, using the matching destination filename.
