#!/usr/bin/env bash
# =============================================================================
# 00-fetch-sources.sh —— 备齐 NDK / Mesa 全量树 / libdrm 源码
# =============================================================================
# 幂等：已存在的部分会跳过。产物：
#   NDK         : 复用 $ANDROID_NDK_* 或下载到 $WORK/ndk/android-ndk-<ver>
#   $SRC/mesa   : MESA_COMMIT 的“全量”工作树（mesa-current 是稀疏+无 blob 克隆，
#                 直接构建会缺 src/egl、include/drm-uapi 等，必须在此展开）
#   $SRC/libdrm : libdrm-<ver> 解包源码
#
# 需要网络（gitlab.freedesktop.org / dl.google.com / dri.freedesktop.org）。
# CI 里 NDK 通常已预装，自动跳过下载。
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

need git
need curl

# ---------------------------------------------------------------------------
# 1) NDK
# ---------------------------------------------------------------------------
if [ -n "${ANDROID_NDK_LATEST_HOME:-}" ] && [ -d "${ANDROID_NDK_LATEST_HOME:-}" ]; then
  log "复用预装 NDK：$ANDROID_NDK_LATEST_HOME"
elif [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME:-}" ]; then
  log "复用预装 NDK：$ANDROID_NDK_HOME"
elif [ -d "$WORK/ndk/android-ndk-${NDK_VERSION}" ]; then
  log "复用已下载 NDK：$WORK/ndk/android-ndk-${NDK_VERSION}"
else
  log "下载 NDK ${NDK_VERSION} -> $WORK/ndk"
  need unzip
  mkdir -p "$WORK/ndk"
  curl -fL --retry 3 -o "$WORK/ndk/$NDK_ZIP" "$NDK_URL_BASE/$NDK_ZIP"
  unzip -q -d "$WORK/ndk" "$WORK/ndk/$NDK_ZIP"
  rm -f "$WORK/ndk/$NDK_ZIP"
  [ -d "$WORK/ndk/android-ndk-${NDK_VERSION}" ] || die "NDK 解包后目录不符预期"
fi

# ---------------------------------------------------------------------------
# 2) Mesa 全量树
# ---------------------------------------------------------------------------
MESA_SRC="$SRC/mesa"
if [ -n "${MESA_SRC_DIR:-}" ] && [ -d "${MESA_SRC_DIR:-}" ]; then
  # 允许直接指定一个已有的全量 mesa 树（例如构建机上的 external/mesa3d）
  MESA_SRC="$MESA_SRC_DIR"
  log "使用外部 Mesa 树：$MESA_SRC"
elif [ -f "$MESA_SRC/VERSION" ]; then
  log "Mesa 树已存在：$MESA_SRC（$(head -1 "$MESA_SRC/VERSION")）"
else
  log "准备 Mesa 全量树 @ ${MESA_COMMIT:0:12} -> $MESA_SRC"
  if [ -d "$MESA_LOCAL_DIR/.git" ]; then
    # 复用本地 mesa-current 的对象库（alternates），只补拉缺失 blob，省带宽
    log "  基于本地稀疏克隆 $MESA_LOCAL_DIR 做 --shared 克隆并展开"
    git clone --shared --no-checkout "$MESA_LOCAL_DIR" "$MESA_SRC"
    git -C "$MESA_SRC" remote set-url origin "$MESA_GIT"
  else
    log "  本地无 mesa-current，直接 blob:none 克隆 $MESA_GIT"
    git clone --filter=blob:none --no-checkout "$MESA_GIT" "$MESA_SRC"
  fi
  # 关掉可能继承来的稀疏规则，确保 src/egl、include/drm-uapi 等全部落地
  git -C "$MESA_SRC" sparse-checkout disable 2>/dev/null || true
  git -C "$MESA_SRC" checkout "$MESA_COMMIT"
fi

# 校验关键源文件确实存在（对应清单 6.2：必须含 panthor KMD 与 PanVK Android 集成）
for f in \
  src/panfrost/lib/kmod/panthor_kmod.c \
  src/panfrost/vulkan/panvk_android.c \
  include/drm-uapi/panthor_drm.h \
  src/egl/meson.build \
  src/gbm/meson.build ; do
  [ -f "$MESA_SRC/$f" ] || die "Mesa 树不完整，缺 $f（稀疏未展开？重跑本脚本或删 $MESA_SRC）"
done
log "  Mesa 关键源校验通过（panthor_kmod.c / panvk_android.c / panthor_drm.h / egl / gbm）"

# ---------------------------------------------------------------------------
# 3) libdrm 源码
# ---------------------------------------------------------------------------
LIBDRM_SRC="$SRC/libdrm-${LIBDRM_VERSION}"
if [ -d "$LIBDRM_SRC" ]; then
  log "libdrm 源码已存在：$LIBDRM_SRC"
else
  log "下载 libdrm ${LIBDRM_VERSION} -> $SRC"
  need xz
  curl -fL --retry 3 -o "$SRC/libdrm-${LIBDRM_VERSION}.tar.xz" "$LIBDRM_URL"
  tar -xf "$SRC/libdrm-${LIBDRM_VERSION}.tar.xz" -C "$SRC"
  rm -f "$SRC/libdrm-${LIBDRM_VERSION}.tar.xz"
  [ -d "$LIBDRM_SRC" ] || die "libdrm 解包失败"
fi

log "取源完成。下一步：scripts/gen-android-sysroot.sh && scripts/10-build-libdrm.sh"
