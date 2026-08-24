# Configure Logs

Store per-ABI FFmpeg `ffbuild/config.log` files as GitHub Release assets for the
matching app release:

- `arm64-v8a.config.log`
- `armeabi-v7a.config.log`
- `x86_64.config.log`

These logs are useful for confirming the exact configure flags and checking that
the FFmpeg license line remains LGPL, with no `--enable-gpl` or
`--enable-nonfree`.
