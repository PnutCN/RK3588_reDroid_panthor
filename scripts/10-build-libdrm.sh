#!/usr/bin/env bash
# =============================================================================
# 10-build-libdrm.sh —— 用 NDK cross-file 交叉构建 libdrm，安装进垫片 sysroot
# =============================================================================
# 产物（装入 $SHIM）：
#   $SHIM/lib/libdrm.so   <- Android 无版本 .so（SONAME=libdrm.so，见文件末校验说明）
#   $SHIM/lib/pkgconfig/libdrm.pc      <- Mesa 的 dependency('libdrm') 靠它
#   $SHIM/include/{xf86drm.h,drm.h,drm_mode.h,...}
#
# 说明（对应清单 6.2 第 3 条）：
#   * 只需要 libdrm “核心”库；所有 vendor 子模块(intel/amdgpu/nouveau/...)关闭。
#   * panthor 的 UAPI 头由 Mesa 自带(include/drm-uapi/panthor_drm.h)，libdrm 无
#     panthor 子模块，故此处不必、也无法“打开 panthor”。Mesa 的 panfrost winsys
#     通过 libdrm 的 drmIoctl 直接发 DRM_IOCTL_PANTHOR_*。
#   * 版本需 >= Mesa 要求(2.4.109)，见 VERSIONS.env:LIBDRM_VERSION。
#
# 前置：先跑 gen-android-sysroot.sh（生成 cross-file）。
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

need meson
need ninja
resolve_ndk

LIBDRM_SRC="$SRC/libdrm-${LIBDRM_VERSION}"
[ -d "$LIBDRM_SRC" ] || die "缺 libdrm 源码：先跑 scripts/00-fetch-sources.sh"
[ -f "$CROSS_FILE" ] || die "缺 cross-file：先跑 scripts/gen-android-sysroot.sh"

BUILD="$LIBDRM_SRC/build-android-${TARGET_ARCH}"
log "配置 libdrm 交叉构建 -> $BUILD"
rm -rf "$BUILD"

# 关闭一切 vendor 子模块与测试，只留 libdrm 核心。
# 选项类型须与 libdrm 2.4.123/meson_options.txt 一致，否则 meson setup 直接报错：
#   * feature 类型(intel/radeon/amdgpu/nouveau/vmwgfx/freedreno/vc4/etnaviv/tegra/
#     exynos/omap/cairo-tests/man-pages/valgrind) 只收 enabled/disabled/auto；
#   * boolean 类型(udev/tests/install-test-programs) 才收 true/false。
# libkms 自 2.4.113 起已从 libdrm 移除，不能再传 -Dlibkms（否则 "Unknown options"）。
# bionic 下 pthread 在 libc，无需 pthread-stubs。
meson setup "$BUILD" "$LIBDRM_SRC" \
  --cross-file="$CROSS_FILE" \
  --prefix="$SHIM" \
  --libdir=lib \
  --buildtype=release \
  --default-library=shared \
  -Dintel=disabled \
  -Dradeon=disabled \
  -Damdgpu=disabled \
  -Dnouveau=disabled \
  -Dvmwgfx=disabled \
  -Dfreedreno=disabled \
  -Dvc4=disabled \
  -Detnaviv=disabled \
  -Dtegra=disabled \
  -Dexynos=disabled \
  -Domap=disabled \
  -Dcairo-tests=disabled \
  -Dman-pages=disabled \
  -Dvalgrind=disabled \
  -Dudev=false \
  -Dtests=false \
  -Dinstall-test-programs=false

log "编译 + 安装 libdrm 到 $SHIM"
ninja -C "$BUILD"
ninja -C "$BUILD" install

# 解析实际安装的 libdrm 共享库名：
#   Android(NDK clang 预定义 __ANDROID__)下 libdrm 上游故意构建“无版本”的 libdrm.so
#   （SONAME=libdrm.so，符合 AOSP 约定；见 libdrm meson.build:54 android=cc.compiles(__ANDROID__)
#    与 :267 "Build an unversioned so on android"）。非 Android 才是 libdrm.so.2.4.0 + 软链。
#   故按实际存在者取，不写死 .so.2（run #3 正是死写 libdrm.so.2 才误报失败）。
LIBDRM_SO=""
for cand in libdrm.so libdrm.so.2; do
  [ -e "$SHIM/lib/$cand" ] && { LIBDRM_SO="$SHIM/lib/$cand"; break; }
done
[ -n "$LIBDRM_SO" ]         || die "libdrm.so(.2) 未安装到 $SHIM/lib"
[ -f "$SHIM_PC/libdrm.pc" ] || die "libdrm.pc 未生成到 $SHIM_PC"
log "  libdrm 就绪：$(readlink -f "$LIBDRM_SO")"
log "  libdrm.pc : $(grep -m1 '^Version:' "$SHIM_PC/libdrm.pc")"

# 交叉产物 ABI 快检：必须是 AArch64 / ELF64，绝不能是宿主 x86-64
if command -v readelf >/dev/null 2>&1; then
  machine="$(readelf -h "$LIBDRM_SO" | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}')"
  log "  $(basename "$LIBDRM_SO") Machine = $machine"
  case "$machine" in *AARCH64*|*aarch64*) : ;; *) die "libdrm 不是 arm64（Machine=$machine），cross-file 有误";; esac
fi

log "libdrm 完成。下一步：scripts/20-build-mesa.sh"
