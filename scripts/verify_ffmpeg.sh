#!/usr/bin/env bash
#
# verify_ffmpeg.sh — FFmpeg 交叉编译产物门禁校验
#
# 对应设计：doc/v1/03-交叉编译裁剪版LGPL-FFmpeg.md §6/§9，把「验证清单」变成可重复执行的门禁。
#
# 校验项：
#   1. 六个 libav*.so 齐备（avcodec/avformat/avfilter/avutil/swresample/swscale）
#   2. 16KB 对齐：每个 .so 的 LOAD 段 Align 必须 0x4000(16KB) 或 0x10000(64KB)，
#      出现 0x1000(4KB) 即 FAIL（03 §6 红线，会在 16KB 页设备崩溃）
#   3. （可选 --check-config）LGPL 洁净：config.log license 行为 LGPL，无 gpl/nonfree
#
# 用法：
#   NDK=/path/to/ndk INSTALL_ROOT=/path/out bash scripts/ffmpeg/verify_ffmpeg.sh
#   # 校验 configure 配置：
#   bash scripts/ffmpeg/verify_ffmpeg.sh --check-config /path/ffbuild/config.log
#   # 校验单个 readelf 输出（CI / 测试 fixture）：
#   bash scripts/ffmpeg/verify_ffmpeg.sh --check-readelf-file dump.txt
#
# 退出码：全通过 0，任一 fail 1。

set -euo pipefail

REQUIRED_LIBS=(avcodec avformat avfilter avutil swresample swscale)
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86_64}"

RED=""; GRN=""; RST=""
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'; fi
pass() { echo "${GRN}PASS${RST} $*"; }
fail() { echo "${RED}FAIL${RST} $*" >&2; FAILED=1; }
FAILED=0

# ---- 解析 llvm-readelf -l 输出，判定 LOAD 段对齐 ----
# 入参：readelf -l 的文本。规则：所有 LOAD 段 Align 须 ∈ {0x4000, 0x10000}；出现 0x1000 判 fail。
check_readelf_text() {
  local label="$1" text="$2"
  local load_lines
  load_lines="$(echo "$text" | grep -E '\bLOAD\b' || true)"
  if [ -z "$load_lines" ]; then
    fail "${label}：未找到 LOAD 段（readelf 输出异常）"
    return
  fi
  # LOAD 行最后一列是 Align，形如 0x4000 / 0x1000 / 0x10000
  local aligns bad=0
  aligns="$(echo "$load_lines" | awk '{print $NF}')"
  while IFS= read -r a; do
    case "$a" in
      0x4000|0x10000) : ;;                       # 16KB / 64KB 均可加载
      0x1000)  fail "${label}：LOAD 段 Align=${a}（4KB 未对齐，16KB 页设备会崩溃）"; bad=1 ;;
      *)       fail "${label}：LOAD 段 Align=${a}（非预期，需人工核对）"; bad=1 ;;
    esac
  done <<< "$aligns"
  [ "$bad" -eq 0 ] && pass "${label}：LOAD 段对齐合规（$(echo "$aligns" | tr '\n' ' '))"
}

# ---- 模式 A：直接校验一份 readelf 输出文件（CI / fixture）----
if [ "${1:-}" = "--check-readelf-file" ]; then
  [ -n "${2:-}" ] || { echo "用法：--check-readelf-file <dump.txt>" >&2; exit 2; }
  check_readelf_text "$(basename "$2")" "$(cat "$2")"
  exit "$FAILED"
fi

# ---- 模式 B：校验 configure 的 LGPL 洁净 ----
if [ "${1:-}" = "--check-config" ]; then
  cfg="${2:-}"
  [ -f "$cfg" ] || { echo "用法：--check-config <ffbuild/config.log 或 config.h>" >&2; exit 2; }
  if grep -Eq 'License:[[:space:]]*LGPL version 2.1 or later' "$cfg"; then
    pass "LGPL：license 行为 LGPL version 2.1 or later"
  elif grep -Eq 'License:[[:space:]]*(GPL|nonfree)' "$cfg"; then
    fail "LGPL：license 行含 GPL/nonfree——洁净被破坏"
  else
    echo "WARN：未在  找到 License 行，尝试检查 --enable-gpl/nonfree 痕迹"
  fi
  if grep -Eq -- '--enable-(gpl|nonfree)' "$cfg"; then
    fail "LGPL：检测到 --enable-gpl / --enable-nonfree"
  else
    pass "LGPL：未使用 --enable-gpl / --enable-nonfree"
  fi
  exit "$FAILED"
fi

# ---- 模式 C（默认）：校验 INSTALL_ROOT 下三 ABI 产物 ----
[ -n "${INSTALL_ROOT:-}" ] || { echo "ERROR：INSTALL_ROOT 未设置" >&2; exit 2; }
[ -d "$INSTALL_ROOT" ] || { echo "ERROR：INSTALL_ROOT 不是目录：$INSTALL_ROOT" >&2; exit 2; }

# readelf：优先 NDK 自带 llvm-readelf
READELF=""
if [ -n "${NDK:-}" ]; then
  case "$(uname -s)" in
    Darwin) HOST_TAG="darwin-x86_64" ;;
    Linux)  HOST_TAG="linux-x86_64" ;;
  esac
  cand="$NDK/toolchains/llvm/prebuilt/${HOST_TAG:-}/bin/llvm-readelf"
  [ -x "$cand" ] && READELF="$cand"
fi
[ -z "$READELF" ] && READELF="$(command -v llvm-readelf || command -v readelf || true)"
[ -n "$READELF" ] || { echo "ERROR：找不到 llvm-readelf/readelf（设置 NDK 或装 binutils）" >&2; exit 2; }
echo "使用 readelf：$READELF"

for abi in $ABIS; do
  echo ""
  echo "==== 校验 ABI：$abi ===="
  libdir="$INSTALL_ROOT/${abi}/lib"
  if [ ! -d "$libdir" ]; then
    fail "${abi}：缺少 $libdir"
    continue
  fi
  # 1. 六库齐备
  for lib in "${REQUIRED_LIBS[@]}"; do
    so="$libdir/lib${lib}.so"
    if [ -f "$so" ]; then
      pass "${abi}/lib${lib}.so 存在"
      # 2. 16KB 对齐
      check_readelf_text "${abi}/lib${lib}.so" "$("$READELF" -l "$so")"
    else
      fail "${abi}：缺少 lib${lib}.so"
    fi
  done
done

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "${GRN}==== 全部校验通过 ====${RST}"
else
  echo "${RED}==== 校验存在失败项，见上 ====${RST}"
fi
exit "$FAILED"
