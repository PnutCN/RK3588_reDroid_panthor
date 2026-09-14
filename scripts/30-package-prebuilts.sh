#!/usr/bin/env bash
# =============================================================================
# 30-package-prebuilts.sh —— 把交叉构建产物落位成 device_redroid-prebuilts 布局
# =============================================================================
# 目标布局（对应 remote-android/device_redroid-prebuilts 的 Android.mk 期望）：
#   prebuilts/arm64/
#     lib/egl/libEGL_mesa.so  libGLESv1_CM_mesa.so  libGLESv2_mesa.so
#     lib/dri/libgallium_dri.so  +  panfrost_dri.so/kmsro_dri.so(->libgallium_dri.so 软链)
#     lib/hw/libvulkan_panfrost.so
#     lib/libgbm_mesa.so.1(.0.0)  libdrm.so(无版本)  libc++_shared.so  [glapi 已并入 libgallium_dri]
#     share/vulkan/icd.d/panfrost_icd.*.json   (可选)
#
# 注意（对应清单 6.3）：
#   * gralloc.gbm.so / hwcomposer.redroid.so / audio.primary.redroid.so / uinputd /
#     vncserver 等 **不是** Mesa 产物，来自 reDroid 自身源码或其预编译包，
#     本脚本不生成、不覆盖它们；合并进完整 prebuilts 树时保持上游原样即可。
#   * 本脚本只负责 Mesa/libdrm 派生的那部分 .so，可单独产出到 $OUT，
#     也可用 PREBUILTS_DST 直接写进一个已 checkout 的 device_redroid-prebuilts 树。
#
# 环境变量：
#   PREBUILTS_DST  目标 prebuilts/<arch> 目录（默认 $OUT/prebuilts/arm64）
#   STRIP=1        用 NDK llvm-strip 精简符号（默认 0，保留符号便于 readelf 校验）
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

resolve_ndk

PREFIX=/vendor; LIBDIR=lib64
STAGE_LIB="$STAGE$PREFIX/$LIBDIR"
[ -d "$STAGE_LIB" ] || die "缺 Mesa 安装产物：先跑 scripts/20-build-mesa.sh"

DST="${PREBUILTS_DST:-$OUT/$PREBUILT_LAYOUT_ARM64}"
log "打包到：$DST"
rm -rf "$DST"
mkdir -p "$DST/lib/egl" "$DST/lib/dri" "$DST/lib/hw" "$DST/share/vulkan/icd.d"

STRIP="${STRIP:-0}"
maybe_strip() { [ "$STRIP" = "1" ] && "$NDK_BIN/llvm-strip" --strip-unneeded "$1" 2>/dev/null || true; }

# 复制一个（可能带版本后缀/软链的）库族到目标目录，保留软链关系
# copy_libs <src_dir> <glob> <dst_dir>
copy_libs() {
  local sdir="$1" glob="$2" ddir="$3" f base
  mkdir -p "$ddir"
  shopt -s nullglob
  for f in "$sdir"/$glob; do
    base="$(basename "$f")"
    if [ -L "$f" ]; then
      ln -sf "$(readlink "$f")" "$ddir/$base"          # 保留相对软链
    else
      cp -a "$f" "$ddir/$base"; maybe_strip "$ddir/$base"
    fi
  done
  shopt -u nullglob
}

# ---- EGL / GLES -> lib/egl/ ----
log "  EGL/GLES -> lib/egl/"
copy_libs "$STAGE_LIB" 'libEGL_mesa.so*'        "$DST/lib/egl"
copy_libs "$STAGE_LIB" 'libGLESv1_CM_mesa.so*'  "$DST/lib/egl"
copy_libs "$STAGE_LIB" 'libGLESv2_mesa.so*'     "$DST/lib/egl"

# ---- Gallium megadriver + 每驱动软链 -> lib/dri/ ----
# Android 下 libgallium_dri.so 无版本、装在 $libdir 根（不在 $libdir/dri），且 Mesa 26.3 的
# gallium dri target 不再自动铺 panfrost_dri.so 软链，故用 find 定位后自建软链。
log "  Gallium DRI -> lib/dri/"
GALLIUM_DRI_SRC="$(find "$STAGE" -name 'libgallium_dri.so' 2>/dev/null | head -1)"
if [ -n "$GALLIUM_DRI_SRC" ]; then
  cp -a "$GALLIUM_DRI_SRC" "$DST/lib/dri/libgallium_dri.so"; maybe_strip "$DST/lib/dri/libgallium_dri.so"
  copy_libs "$STAGE_LIB/dri" '*_dri.so' "$DST/lib/dri"   # 若 mesa 另生成了 *_dri.so 软链则一并保留
else
  log "  警告：未找到 libgallium_dri.so（gallium 驱动未构建？）"
fi
# 兜底：确保 panfrost_dri.so 软链存在（device_redroid-prebuilts 的 Android.mk 靠 find -type l 识别驱动）
[ -e "$DST/lib/dri/panfrost_dri.so" ] || ln -sf libgallium_dri.so "$DST/lib/dri/panfrost_dri.so"

# ---- PanVK -> lib/hw/libvulkan_panfrost.so ----
log "  PanVK -> lib/hw/"
copy_libs "$STAGE_LIB" 'libvulkan_panfrost.so*' "$DST/lib/hw"

# ---- GBM / glapi -> lib/ ----
log "  GBM/glapi -> lib/"
copy_libs "$STAGE_LIB" 'libgbm*.so*'   "$DST/lib"   # android(SDK>=30) 名为 libgbm_mesa.so.1.0.0
copy_libs "$STAGE_LIB" 'libglapi.so*'  "$DST/lib"   # glapi 通常并入 libgallium_dri，无独立 .so 时为空，无妨

# ---- libdrm（我们在 10-build-libdrm.sh 装进 $SHIM）-> lib/ ----
log "  libdrm -> lib/"
copy_libs "$SHIM/lib" 'libdrm.so*' "$DST/lib"

# ---- libc++_shared.so（NDK 提供；PanVK/驱动用 libc++）-> lib/ ----
log "  libc++_shared -> lib/"
cxx=""
for c in \
  "$NDK_SYSROOT/usr/lib/$NDK_ABI/libc++_shared.so" \
  "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$NDK_ABI/libc++_shared.so" ; do
  [ -f "$c" ] && { cxx="$c"; break; }
done
[ -n "$cxx" ] || die "找不到 NDK libc++_shared.so（$NDK_ABI）"
cp -a "$cxx" "$DST/lib/libc++_shared.so"; maybe_strip "$DST/lib/libc++_shared.so"

# ---- Vulkan ICD json（可选，Android 主要靠 ro.hardware.vulkan=panfrost）----
if ls "$STAGE$PREFIX/etc/vulkan/icd.d/"*.json >/dev/null 2>&1; then
  log "  Vulkan ICD json -> share/vulkan/icd.d/"
  cp -a "$STAGE$PREFIX/etc/vulkan/icd.d/"*.json "$DST/share/vulkan/icd.d/" 2>/dev/null || true
fi

# ---- 汇总 ----
log "打包完成，清单："
( cd "$DST" && find . -type f -o -type l | sort | sed 's#^\./##' | while read -r p; do
    if [ -L "$p" ]; then printf '  %-42s -> %s\n' "$p" "$(readlink "$p")"; else printf '  %-42s %s\n' "$p" "$(du -h "$p" | cut -f1)"; fi
  done )

cat > "$DST/PACKAGE-INFO.txt" <<EOF
Android Mesa + PanVK + GBM 预编译产物（脚手架生成）
生成时间   : $(date -u +%Y-%m-%dT%H:%M:%SZ)
Mesa commit: ${MESA_COMMIT}
libdrm     : ${LIBDRM_VERSION}
NDK        : ${NDK_VERSION}  (API ${ANDROID_API})
gallium    : ${GALLIUM_DRIVERS:-panfrost}
vulkan     : ${VULKAN_DRIVERS:-panfrost} (PanVK)
目标 ABI   : ${TARGET_ARCH} (aarch64-linux-android)
说明       : 仅含 Mesa/libdrm 派生库；gralloc.gbm/hwcomposer.redroid/audio/uinputd/
             vncserver 等沿用 device_redroid-prebuilts 上游原样，未在此覆盖。
EOF
log "写入 $DST/PACKAGE-INFO.txt"
log "下一步：scripts/40-verify-panthor.sh（校验含 panthor KMD、ABI、NEEDED）"
