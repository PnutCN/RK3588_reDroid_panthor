#!/usr/bin/env bash
# =============================================================================
# gen-android-sysroot.sh —— 渲染 meson cross-file + 组装 Android 垫片 sysroot
# =============================================================================
# 做三件事：
#   1) 用 NDK 路径渲染 cross/android-aarch64.ini.in -> $SHIM/cross-*.ini
#   2) 生成 meson 所需的全部 pkg-config 垫片(.pc)：
#        NDK 原生：zlib / log / sync / nativewindow
#        AOSP 专有：cutils / hardware / android-hwvulkan-headers (+backtrace 可选)
#        libdrm 由 10-build-libdrm.sh 安装时自带 .pc，不在此生成
#   3) 拉取 NDK 缺失的 AOSP 专有头到 $SHIM_INCLUDE，并为 libcutils/libhardware
#      生成链接期 stub .so（运行时用设备上真实库解析同名 SONAME）
#
# 两种模式：
#   默认(ANDROID_STUB=1): -Dandroid-stub=true，用 mesa 自带 src/android_stub 头/stub库——纯 NDK
#                         独立构建的【标准生产路径】(run #8 已验证：真实 arm64 Panthor 驱动，无 libLLVM)。
#   ANDROID_STUB=0(full) : 拉真实 AOSP 头 + 造 stub .so，走 dependency('cutils'/'hardware'/...)；
#                         需完整 AOSP 头 sysroot（含 system/graphics.h；lineage-20.0 的 frameworks_native
#                         无 graphics-base 故缺此头），仅在自备 AOSP 头时启用。
#
# 依赖：git、NDK（resolve_ndk）。full 模式(ANDROID_STUB=0)另需网络拉 LineageOS 镜像。
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

need git
resolve_ndk

ANDROID_STUB="${ANDROID_STUB:-1}"   # 默认 stub=true：纯 NDK 独立构建的生产路径（mesa android_stub）

# NDK 里 API 相关的 .so 目录（libsync/libnativewindow/liblog/libz/libandroid）
NDK_LIBDIR="$NDK_SYSROOT/usr/lib/$NDK_ABI/$ANDROID_API"
[ -d "$NDK_LIBDIR" ] || NDK_LIBDIR="$NDK_SYSROOT/usr/lib/$NDK_ABI"
[ -d "$NDK_LIBDIR" ] || die "找不到 NDK 库目录：$NDK_SYSROOT/usr/lib/$NDK_ABI[/API]"
NDK_INCDIR="$NDK_SYSROOT/usr/include"

# ---------------------------------------------------------------------------
# 1) 渲染 cross-file
# ---------------------------------------------------------------------------
log "渲染 meson cross-file -> $CROSS_FILE"
TEMPLATE="$SCAFFOLD/cross/android-aarch64.ini.in"
[ -f "$TEMPLATE" ] || die "缺模板：$TEMPLATE"

# ccache 可选：装了就用，没装留空
if command -v ccache >/dev/null 2>&1; then CCACHE_TOKEN="'ccache',"; else CCACHE_TOKEN=""; fi

sed \
  -e "s#@NDK_BIN@#$NDK_BIN#g" \
  -e "s#@NDK_TRIPLE@#$NDK_TRIPLE#g" \
  -e "s#@ANDROID_API@#$ANDROID_API#g" \
  -e "s#@NDK_SYSROOT@#$NDK_SYSROOT#g" \
  -e "s#@SHIM_PC@#$SHIM_PC#g" \
  -e "s#@SHIM_INCLUDE@#$SHIM_INCLUDE#g" \
  -e "s#@SHIM_LIB@#$SHIM_LIB#g" \
  -e "s#@CPU_FAMILY@#$MESON_CPU_FAMILY#g" \
  -e "s#@CPU@#$MESON_CPU#g" \
  -e "s#@CCACHE@#$CCACHE_TOKEN#g" \
  "$TEMPLATE" > "$CROSS_FILE"

# 渲染后不应残留任何占位符
if grep -q '@[A-Z_]*@' "$CROSS_FILE"; then
  grep -n '@[A-Z_]*@' "$CROSS_FILE" >&2 || true
  die "cross-file 仍有未替换占位符"
fi

# ---------------------------------------------------------------------------
# 2) pkg-config 垫片
# ---------------------------------------------------------------------------
log "生成 pkg-config 垫片 -> $SHIM_PC"

# --- NDK 原生库（头/库都在 NDK sysroot，clang --target 会自动搜库路径）---
gen_pc zlib       1.2.11 "Android NDK zlib"        "-I$NDK_INCDIR"                 "-L$NDK_LIBDIR -lz"
gen_pc log        1.0    "Android liblog"          "-I$SHIM_INCLUDE -I$NDK_INCDIR"  "-L$NDK_LIBDIR -llog"
gen_pc sync       1.0    "Android libsync"         "-I$SHIM_INCLUDE -I$NDK_INCDIR"  "-L$NDK_LIBDIR -lsync"
gen_pc nativewindow 1.0  "Android libnativewindow" "-I$SHIM_INCLUDE -I$NDK_INCDIR"  "-L$NDK_LIBDIR -lnativewindow"

# --- AOSP 专有：头在 shim，库用 stub（full 模式）或纯头（stub 模式）---
if [ "$ANDROID_STUB" = "1" ]; then
  # android-stub 冒烟：meson 不会 dependency('cutils'/'hardware')，这里只放占位 .pc
  gen_pc cutils   1.0 "Android libcutils (stub-mode, header-only)" "-I$SHIM_INCLUDE" ""
  gen_pc hardware 1.0 "Android libhardware (stub-mode, header-only)" "-I$SHIM_INCLUDE" ""
else
  gen_pc cutils   1.0 "Android libcutils"   "-I$SHIM_INCLUDE" "-L$SHIM_LIB -lcutils"
  gen_pc hardware 1.0 "Android libhardware" "-I$SHIM_INCLUDE" "-L$SHIM_LIB -lhardware"
  # hwvulkan 头（PanVK 作为 Android Vulkan ICD 需要 hwvulkan/hwvulkan.h）
  gen_pc android-hwvulkan-headers 1.0 "Android hwvulkan headers" "-I$SHIM_INCLUDE" ""
fi

# ---------------------------------------------------------------------------
# 3) AOSP 专有头 + stub .so（仅 full 模式）
# ---------------------------------------------------------------------------
if [ "$ANDROID_STUB" = "1" ]; then
  log "ANDROID_STUB=1：用 mesa android_stub，跳过 AOSP 头/stub 拉取（纯 NDK 独立构建的生产路径）"
else
  KEY_HEADERS=(cutils/native_handle.h hardware/hardware.h sync/sync.h \
               log/log.h system/graphics.h nativewindow/ANativeWindowBase.h)
  missing=0
  for h in "${KEY_HEADERS[@]}"; do [ -f "$SHIM_INCLUDE/$h" ] || missing=1; done

  if [ "$missing" = "0" ] && [ -f "$SHIM_LIB/libcutils.so" ]; then
    log "AOSP 垫片头/stub 已存在，跳过拉取（删除 $SHIM 可强制重建）"
  else
    log "拉取 AOSP 专有头（$AOSP_MIRROR @ $AOSP_TAG）到 $SHIM_INCLUDE"
    fetch_aosp_headers
  fi

  log "生成链接期 stub .so（libcutils / libhardware）到 $SHIM_LIB"
  make_stub_lib libcutils.so
  make_stub_lib libhardware.so
fi

log "sysroot 就绪：cross-file=$CROSS_FILE"
log "  include=$SHIM_INCLUDE"
log "  lib=$SHIM_LIB  pc=$SHIM_PC"
