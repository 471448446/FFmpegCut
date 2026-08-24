#!/usr/bin/env bash
#
# build_ffmpeg_android.sh — 交叉编译裁剪版纯 LGPL、16KB 对齐的 FFmpeg（三 ABI）
#
# 对应设计：doc/v1/03-交叉编译裁剪版LGPL-FFmpeg.md §4/§5
# 硬约束（CLAUDE.md 全局，不可妥协）：
#   1. 离线      → --disable-network（不引入 openssl 等网络依赖）
#   2. 16KB 对齐 → --extra-ldflags="-Wl,-z,max-page-size=16384"，每 ABI 每 .so
#   3. 三 ABI    → arm64-v8a + armeabi-v7a(必选,--enable-neon) + x86_64(调试)
#   4. LGPL 洁净 → 不传 --enable-gpl / --enable-nonfree；不 enable x264/x265/fdk-aac/xvid
#
# 产物不进版本库（体积大）：编译后落 INSTALL_ROOT/<abi>/{lib,include}，
# 由集成步骤拷入 app/src/main/jniLibs/<abi>/（见 doc/v1/任务拆分-FFmpeg交叉编译.md F3）。
#
# 用法：
#   FFMPEG_SRC=/path/to/ffmpeg NDK=/path/to/ndk INSTALL_ROOT=/path/out \
#     bash scripts/ffmpeg/build_ffmpeg_android.sh
#
# 环境变量（缺失即报错）：
#   FFMPEG_SRC    解压后的 FFmpeg 源码目录（建议 7.x+）
#   NDK           Android NDK 路径（r27+，默认探 $ANDROID_HOME/ndk/<最新>）
#   INSTALL_ROOT  产物安装根目录
# 可选：
#   API           minSdk，默认 24
#   ABIS          空格分隔的 ABI 子集，默认 "arm64-v8a armeabi-v7a x86_64"
#   JOBS          并行度，默认 CPU 核数

set -euo pipefail

# ===== 参数解析与校验 =====
API="${API:-24}"
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86_64}"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

[ -n "${FFMPEG_SRC:-}" ] || { usage; die "FFMPEG_SRC 未设置（FFmpeg 源码目录）"; }
[ -d "$FFMPEG_SRC" ] || die "FFMPEG_SRC 不是目录：$FFMPEG_SRC"
[ -f "$FFMPEG_SRC/configure" ] || die "$FFMPEG_SRC 下无 configure，非 FFmpeg 源码目录"

# NDK：未给则尝试从 ANDROID_HOME/ndk 取最新一个
if [ -z "${NDK:-}" ]; then
  if [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME/ndk" ]; then
    NDK="$ANDROID_HOME/ndk/$(ls "$ANDROID_HOME/ndk" | sort -V | tail -1)"
    echo "NDK 未设置，自动选用：$NDK"
  fi
fi
[ -n "${NDK:-}" ] || die "NDK 未设置，且无法从 \$ANDROID_HOME/ndk 推断"
[ -d "$NDK" ] || die "NDK 不是目录：$NDK"

[ -n "${INSTALL_ROOT:-}" ] || die "INSTALL_ROOT 未设置（产物安装根目录）"

# 记录调用目录，供结束时 License 拷贝使用（build_abi 内部 cd 会改 cwd）。
ORIG_CWD="$PWD"

# 主机 tag：macOS=darwin-x86_64，Linux=linux-x86_64（NDK 目录里只有一个 prebuilt）
case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;
  Linux)  HOST_TAG="linux-x86_64" ;;
  *) die "未知主机平台：$(uname -s)" ;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
[ -d "$TOOLCHAIN" ] || die "找不到 NDK toolchain：$TOOLCHAIN"

# 并行度
if [ -z "${JOBS:-}" ]; then
  JOBS="$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi

echo "==== FFmpeg Android 交叉编译 ===="
echo "  FFMPEG_SRC   = $FFMPEG_SRC"
echo "  NDK          = $NDK"
echo "  HOST_TAG     = $HOST_TAG"
echo "  API          = $API"
echo "  INSTALL_ROOT = $INSTALL_ROOT"
echo "  ABIS         = $ABIS"
echo "  JOBS         = $JOBS"

# ===== 裁剪 flags（加法策略，与 03 §4 逐项对应）=====
# 三条硬约束在此固化：--disable-network（离线）、无 --enable-gpl/--enable-nonfree（LGPL）、
# 16KB 对齐经 --extra-ldflags 注入（见 build_abi）。
FFMPEG_FLAGS_BASE=(
  --target-os=android
  --enable-cross-compile
  --disable-everything --disable-autodetect
  --disable-programs --disable-doc --disable-static --disable-network
  --enable-shared --enable-pic --enable-small
  --enable-zlib
  --enable-avcodec --enable-avformat --enable-avutil
  --enable-swresample --enable-swscale --enable-avfilter
  # ---- 解码器（解码专利风险低，系统层已授权）----
  --enable-decoder=h264 --enable-decoder=hevc
  --enable-decoder=vp8 --enable-decoder=vp9 --enable-decoder=mpeg4
  --enable-decoder=gif
  --enable-decoder=png --enable-decoder=mjpeg --enable-decoder=webp --enable-decoder=bmp
  --enable-decoder=aac --enable-decoder=mp3 --enable-decoder=pcm_s16le
  # ---- 编码器（仅 GIF/图片，零专利风险；不 enable 任何音视频编码器）----
  --enable-encoder=gif --enable-encoder=png --enable-encoder=mjpeg
  # ---- 滤镜（GIF 调参 + 视频 scale/crop/trim）----
  --enable-filter=scale --enable-filter=fps --enable-filter=crop --enable-filter=pad
  --enable-filter=format --enable-filter=setsar --enable-filter=setdar
  --enable-filter=split --enable-filter=palettegen --enable-filter=paletteuse
  --enable-filter=setpts --enable-filter=trim
  # ---- demuxer ----
  --enable-demuxer=mov --enable-demuxer=matroska --enable-demuxer=avi
  --enable-demuxer=flv --enable-demuxer=gif --enable-demuxer=image2
  --enable-demuxer=image2pipe --enable-demuxer=mp3 --enable-demuxer=aac
  --enable-demuxer=wav --enable-demuxer=ogg
  # ---- muxer（无编码封装 + GIF 输出）----
  --enable-muxer=gif --enable-muxer=mp4 --enable-muxer=matroska
  --enable-muxer=image2 --enable-muxer=null
  # ---- parser ----
  # gif parser 必选：gif demuxer 只按 1024B 块吐原始 packet，需 parser 用
  # ff_combine_frame 重组成完整帧再喂 gif decoder，否则首帧 LZW 数据被截断 → INVALIDDATA。
  --enable-parser=gif
  --enable-parser=h264 --enable-parser=hevc --enable-parser=aac --enable-parser=mjpeg
  # ---- bsf ----
  --enable-bsf=extract_extradata --enable-bsf=h264_mp4toannexb
  --enable-bsf=hevc_mp4toannexb --enable-bsf=aac_adtstoasc
  # ---- protocol（离线：仅本地 file/pipe）----
  --enable-protocol=file --enable-protocol=pipe
)

# ===== 单 ABI 编译 =====
build_abi() {
  local ABI="$1" ARCH="$2" CPU="$3" TRIPLE="$4"
  local SYSROOT="$TOOLCHAIN/sysroot"
  local CC="$TOOLCHAIN/bin/${TRIPLE}${API}-clang"
  local CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
  local AR="$TOOLCHAIN/bin/llvm-ar"
  local RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
  local STRIP="$TOOLCHAIN/bin/llvm-strip"
  local NM="$TOOLCHAIN/bin/llvm-nm"

  [ -x "$CC" ] || die "找不到编译器：${CC}（检查 API=$API 与 NDK 是否匹配）"

  local CFLAGS="-fPIC -O2 -DANDROID -fstack-protector-strong -D_FILE_OFFSET_BITS=64"
  local EXTRA_CFG=""
  # 32 位 armeabi-v7a：必选 NEON（03 §10.6，硬约束第 3 条）
  if [ "$ABI" = "armeabi-v7a" ]; then
    CFLAGS="$CFLAGS -mfpu=neon"
    EXTRA_CFG="--enable-neon"
  fi
  # x86_64 的 SIMD 汇编需要 nasm；本地无 nasm 时降级为 --disable-x86asm（03 §4 提示，
  # x86_64 仅供调试/模拟器，可接受少量性能损失）。arm 无此依赖。
  if [ "$ABI" = "x86_64" ] && ! command -v nasm >/dev/null 2>&1; then
    echo "WARN: 未找到 nasm，x86_64 降级为 --disable-x86asm（装 nasm 可启用 SIMD 汇编）"
    EXTRA_CFG="$EXTRA_CFG --disable-x86asm"
  fi
  # ★ 16KB page size 对齐（硬约束第 2 条，32/64 位 ABI 均适用）
  local LDFLAGS="-Wl,-z,max-page-size=16384"
  local OUT="$INSTALL_ROOT/$ABI"

  echo ""
  echo "==== building ${ABI}（${TRIPLE}, cpu=${CPU}）===="
  cd "$FFMPEG_SRC"
  make clean >/dev/null 2>&1 || true

  ./configure \
    --prefix="$OUT" \
    --arch="$ARCH" --cpu="$CPU" \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --nm="$NM" \
    --sysroot="$SYSROOT" \
    --extra-cflags="$CFLAGS" \
    --extra-ldflags="$LDFLAGS" \
    $EXTRA_CFG \
    "${FFMPEG_FLAGS_BASE[@]}"

  # LGPL 洁净自检：configure 生成的 config.h 里 license 必须是 LGPL
  if grep -q '#define CONFIG_GPL 1' ffbuild/config.h 2>/dev/null; then
    die "${ABI}：检测到 CONFIG_GPL=1，LGPL 洁净被破坏，终止"
  fi

  make -j"$JOBS"
  make install
  # strip 去符号表减体积（保留 unstripped 供崩溃符号化：另行归档，见 03 §10.2）
  for so in "$OUT"/lib/*.so; do
    [ -e "$so" ] && "$STRIP" --strip-unneeded "$so"
  done
  echo "---- $ABI done → $OUT/lib ----"
}

# ABI → (arch, cpu, triple) 映射
for abi in $ABIS; do
  case "$abi" in
    arm64-v8a)   build_abi arm64-v8a   aarch64 armv8-a aarch64-linux-android ;;
    armeabi-v7a) build_abi armeabi-v7a arm     armv7-a armv7a-linux-androideabi ;;
    x86_64)      build_abi x86_64      x86_64  x86-64  x86_64-linux-android ;;
    *) die "未知 ABI：$abi" ;;
  esac
done

echo ""
echo "==== 全部完成 → $INSTALL_ROOT ===="

# LGPL 合规（03 §8）：拷 License 随包。默认落工程 assets（相对调用目录，非 FFMPEG_SRC）。
LICENSE_DEST="${LICENSE_DEST:-$ORIG_CWD/app/src/main/assets/licenses}"
for lic in COPYING.LGPLv2.1 COPYING.LGPLv3; do
  if [ -f "$FFMPEG_SRC/$lic" ] && [ -d "$LICENSE_DEST" ]; then
    cp "$FFMPEG_SRC/$lic" "$LICENSE_DEST/" && echo "License 拷贝：$lic → $LICENSE_DEST/"
  fi
done

echo "下一步：bash scripts/ffmpeg/verify_ffmpeg.sh 校验 16KB 对齐与库齐备，"
echo "        然后把 <abi>/lib/*.so 拷入 app/src/main/jniLibs/<abi>/。"
