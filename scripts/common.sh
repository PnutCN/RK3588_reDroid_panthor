#!/usr/bin/env bash
# =============================================================================
# common.sh —— 所有 android-mesa 脚手架脚本的公共前置
# =============================================================================
# 用法：在每个脚本顶部
#   source "$(dirname "$0")/common.sh"
# 提供：
#   $HERE / $SCAFFOLD / $REPO_ROOT / $WORK        路径
#   VERSIONS.env 中的全部变量
#   $NDK / $NDK_BIN / $NDK_SYSROOT               NDK 解析结果
#   $SHIM / $SHIM_INCLUDE / $SHIM_LIB / $SHIM_PC 垫片 sysroot
#   $CROSS_FILE                                  渲染后的 meson cross-file
#   log/die/need 等辅助函数
# =============================================================================
set -euo pipefail

# ---- 路径解析 ---------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAFFOLD="$(cd "$HERE/.." && pwd)"                 # .../opi5max-panthor/android-mesa
# REPO_ROOT = 分析仓库根（含 mesa-current / device_redroid-prebuilts / ...）
REPO_ROOT="$(cd "$SCAFFOLD/../.." && pwd)"

# 工作目录（可用环境变量覆盖；CI 里指向大容量盘）
WORK="${WORK:-$SCAFFOLD/.work}"
mkdir -p "$WORK"

# ---- 载入冻结版本 -----------------------------------------------------------
# shellcheck source=/dev/null
source "$SCAFFOLD/VERSIONS.env"
# VERSIONS.env 里 MESA_LOCAL_DIR 用了 ${REPO_ROOT:-}，此处补全
MESA_LOCAL_DIR="${MESA_LOCAL_DIR:-$REPO_ROOT/mesa-current}"

SRC="$WORK/src"                 # 源码（mesa 全量 / libdrm 解包）
SHIM="$WORK/sysroot"            # 垫片 sysroot
SHIM_INCLUDE="$SHIM/include"
SHIM_LIB="$SHIM/lib"
SHIM_PC="$SHIM/lib/pkgconfig"
CROSS_FILE="$SHIM/cross-android-${MESON_CPU_FAMILY}.ini"
STAGE="$WORK/stage"             # meson install 的 DESTDIR 暂存
OUT="$WORK/out"                 # 最终 device_redroid-prebuilts 布局
# 原生(host x86_64)构建的 CLC 代码生成工具安装前缀（见 15-build-native-clc-tools.sh）：
#   mesa_clc / vtn_bindgen2 / panfrost_compile —— 仅在【构建期】把 libpan/*.cl 编成
#   SPIR-V→C/NIR 嵌进 arm64 驱动；交叉构建用 -Dmesa-clc=system 从这里的 bin 取用。
NATIVE_TOOLS="$WORK/native-tools"
NATIVE_TOOLS_BIN="$NATIVE_TOOLS/bin"
mkdir -p "$SRC" "$SHIM_INCLUDE" "$SHIM_LIB" "$SHIM_PC" "$STAGE" "$OUT" "$NATIVE_TOOLS_BIN"

# ---- 辅助函数 ---------------------------------------------------------------
log()  { printf '\033[1;34m[android-mesa]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少必需工具：$1（请先安装）"; }

# 解析 NDK：优先环境变量，其次 $WORK/ndk，最后报错提示先跑 00-fetch-sources.sh
resolve_ndk() {
  if [ -n "${NDK:-}" ] && [ -d "$NDK" ]; then :
  elif [ -n "${ANDROID_NDK_LATEST_HOME:-}" ] && [ -d "${ANDROID_NDK_LATEST_HOME:-}" ]; then NDK="$ANDROID_NDK_LATEST_HOME"
  elif [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME:-}" ]; then NDK="$ANDROID_NDK_HOME"
  elif [ -d "$WORK/ndk/android-ndk-${NDK_VERSION}" ]; then NDK="$WORK/ndk/android-ndk-${NDK_VERSION}"
  else die "未找到 NDK。设置 \$ANDROID_NDK_LATEST_HOME/\$ANDROID_NDK_HOME，或先运行 scripts/00-fetch-sources.sh 下载 ${NDK_VERSION}"
  fi
  NDK_PREBUILT="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
  [ -d "$NDK_PREBUILT" ] || die "NDK 结构异常：缺 $NDK_PREBUILT（非 linux-x86_64 主机？请改 common.sh）"
  NDK_BIN="$NDK_PREBUILT/bin"
  NDK_SYSROOT="$NDK_PREBUILT/sysroot"
  [ -x "$NDK_BIN/clang" ] || die "NDK clang 不存在：$NDK_BIN/clang"
  export NDK NDK_BIN NDK_SYSROOT
  log "NDK = $NDK (bin=$NDK_BIN)"
}

# 生成一个指向 NDK/shim 的 pkg-config .pc 垫片
# gen_pc <name> <version> <description> <cflags> <libs>
gen_pc() {
  local name="$1" ver="$2" desc="$3" cflags="$4" libs="$5"
  cat > "$SHIM_PC/${name}.pc" <<EOF
Name: ${name}
Description: ${desc}
Version: ${ver}
Cflags: ${cflags}
Libs: ${libs}
EOF
  log "  .pc: ${name}.pc"
}

# 造一个只含正确 SONAME 的空 stub 共享库（链接期用；运行时由设备真实库解析）
# make_stub_lib <soname>
make_stub_lib() {
  local soname="$1"
  local stub_c="$WORK/_stub.c"
  printf 'void __android_mesa_stub_%s(void) {}\n' \
    "$(echo "$soname" | tr -c 'a-zA-Z0-9' '_')" > "$stub_c"
  "$NDK_BIN/clang" --target="${NDK_TRIPLE}${ANDROID_API}" --sysroot="$NDK_SYSROOT" \
    -shared -Wl,-soname,"$soname" -o "$SHIM_LIB/$soname" "$stub_c"
  log "  stub: $SHIM_LIB/$soname"
}

# 从 pin 的 LineageOS 镜像稀疏拉取 AOSP 专有头到 $SHIM_INCLUDE。
# AOSP_HEADER_REPOS 格式：空格分隔的条目，每条 "repo:incdir1[:incdir2...]"，
# incdir 相对 repo 根，其“内容”被并入 $SHIM_INCLUDE（合并 hardware/ cutils/ 等命名空间）。
fetch_aosp_headers() {
  local aosp_work="$WORK/aosp"
  mkdir -p "$aosp_work"
  local entry repo clone_dir incdir
  for entry in $AOSP_HEADER_REPOS; do
    repo="${entry%%:*}"
    local dirs="${entry#*:}"
    clone_dir="$aosp_work/$repo"
    if [ ! -d "$clone_dir/.git" ]; then
      log "  clone $AOSP_MIRROR/$repo @ $AOSP_TAG (blob:none,sparse)"
      git clone --filter=blob:none --no-checkout --depth 1 \
        --branch "$AOSP_TAG" "$AOSP_MIRROR/$repo.git" "$clone_dir"
      git -C "$clone_dir" sparse-checkout init --cone
    fi
    # 把本条目所有 incdir 交给 sparse-checkout，再 checkout
    local sparse_args=()
    local IFS_BAK="$IFS"; IFS=':'
    for incdir in $dirs; do sparse_args+=("$incdir"); done
    IFS="$IFS_BAK"
    git -C "$clone_dir" sparse-checkout set "${sparse_args[@]}"
    git -C "$clone_dir" checkout "$AOSP_TAG"
    # 并入 shim include
    for incdir in "${sparse_args[@]}"; do
      if [ -d "$clone_dir/$incdir" ]; then
        cp -a "$clone_dir/$incdir/." "$SHIM_INCLUDE/"
      else
        warn "  $repo 未含 $incdir（tag 漂移？请核对 VERSIONS.env）"
      fi
    done
  done
  # 关键头存在性校验（缺则 die，避免后续 meson 报一堆晦涩的找不到头）
  local h
  for h in cutils/native_handle.h hardware/hardware.h sync/sync.h \
           log/log.h system/graphics.h nativewindow/ANativeWindowBase.h; do
    [ -f "$SHIM_INCLUDE/$h" ] || die "AOSP 头缺失：$SHIM_INCLUDE/$h（检查 AOSP_HEADER_REPOS/AOSP_TAG）"
  done
  log "  AOSP 头并入完成：$SHIM_INCLUDE"
}
