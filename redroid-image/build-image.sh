#!/usr/bin/env bash
# =============================================================================
# build-image.sh —— 产出 redroid-rk3588-panthor 镜像：
#   上游 reDroid arm64 镜像（默认 redroid/redroid:13.0.0-latest = Android 13 = LineageOS 20）
#   + 交叉构建的 Panthor 版 Mesa/PanVK/GBM（android-mesa workflow 的 Release 产物）drop-in 替换。
# =============================================================================
# 步骤：解析 Mesa 产物 -> docker pull base -> 探测 base /vendor（布局 + 保留二进制的 libLLVM 依赖）
#       -> inject-mesa.sh 生成 overlay -> docker build -> 导出 /vendor 校验 -> docker save。
#
# 环境变量：
#   MESA_SRC     Mesa 产物：.tar.gz 路径 / 含 prebuilts/arm64 的目录 / Release 直链URL（必填）
#   BASE_IMAGE   基座镜像            (默认 redroid/redroid:13.0.0-latest)
#   OUT_IMAGE    产出镜像 tag        (默认 redroid-rk3588-panthor:lineage-20)
#   WORK         工作目录            (默认 ./.work-image)
#   GPU_CONFIG   panthor 版 gpu_config.sh（默认与本脚本同目录）
#   SAVE_IMAGE   1=docker save 成压缩包（默认 1）；PUBLISH 由 workflow 负责
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[build-image] $*"; }
die()  { echo "[build-image] ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

BASE_IMAGE="${BASE_IMAGE:-redroid/redroid:13.0.0-latest}"
OUT_IMAGE="${OUT_IMAGE:-redroid-rk3588-panthor:lineage-20}"
WORK="${WORK:-$HERE/.work-image}"
GPU_CONFIG="${GPU_CONFIG:-$HERE/gpu_config.sh}"
SAVE_IMAGE="${SAVE_IMAGE:-1}"
MESA_SRC="${MESA_SRC:-}"
[ -n "$MESA_SRC" ] || die "必须给 MESA_SRC（Mesa 产物 tar.gz / 目录 / Release URL）"
have docker || die "缺 docker"
have patchelf || die "缺 patchelf"
READELF="$(command -v readelf || command -v llvm-readelf || true)"; [ -n "$READELF" ] || die "缺 readelf"

mkdir -p "$WORK"

# --- 1) 解析 Mesa 产物 -> $WORK/prebuilts/arm64 -------------------------------
ARM64="$WORK/prebuilts/arm64"
rm -rf "$WORK/prebuilts"; mkdir -p "$WORK/prebuilts"
case "$MESA_SRC" in
  http://*|https://*)
    log "下载 Mesa 产物：$MESA_SRC"
    curl -fsSL --retry 3 -o "$WORK/mesa.tar.gz" "$MESA_SRC" || die "下载失败：$MESA_SRC"
    tar -xzf "$WORK/mesa.tar.gz" -C "$WORK/prebuilts" ;;
  *)
    if [ -d "$MESA_SRC" ]; then
      log "Mesa 产物目录：$MESA_SRC"
      # 允许直接给 .../prebuilts/arm64 或其上层
      if [ -d "$MESA_SRC/lib/egl" ]; then cp -a "$MESA_SRC" "$ARM64"
      elif [ -d "$MESA_SRC/arm64" ]; then cp -a "$MESA_SRC/arm64" "$ARM64"
      else cp -a "$MESA_SRC/." "$WORK/prebuilts/"; fi
    elif [ -f "$MESA_SRC" ]; then
      log "Mesa 产物 tar：$MESA_SRC"
      tar -xzf "$MESA_SRC" -C "$WORK/prebuilts"
    else die "MESA_SRC 既非 URL 也不存在：$MESA_SRC"; fi ;;
esac
[ -d "$ARM64/lib/egl" ] || die "解析后未找到 $ARM64/lib/egl（Mesa 产物布局不符）"
log "Mesa arm64 产物就绪：$ARM64"

# --- 2) 拉 base 镜像（arm64）-------------------------------------------------
log "docker pull --platform linux/arm64 $BASE_IMAGE"
docker pull --platform linux/arm64 "$BASE_IMAGE"

# --- 3) 探测 base /vendor（布局 + 保留二进制是否依赖 libLLVM）-----------------
BASEV="$WORK/base-vendor"; rm -rf "$BASEV"; mkdir -p "$BASEV"
cid="$(docker create --platform linux/arm64 "$BASE_IMAGE")"
docker cp "$cid:/vendor" "$BASEV/" 2>/dev/null || docker cp "$cid:/vendor/." "$BASEV/" || die "无法从 base 导出 /vendor"
docker rm "$cid" >/dev/null
BV64="$BASEV/vendor/lib64"
log "base /vendor/lib64 顶层：$(ls "$BV64" 2>/dev/null | tr '\n' ' ')"
log "base egl：$(ls "$BV64/egl" 2>/dev/null | tr '\n' ' ')"
log "base dri：$(ls "$BV64/dri" 2>/dev/null | tr '\n' ' ')"
log "base hw ：$(ls "$BV64/hw" 2>/dev/null | tr '\n' ' ')"
log "base libLLVM*：$(find "$BV64" -maxdepth 1 -name 'libLLVM*' 2>/dev/null | xargs -rn1 basename | tr '\n' ' ')"
for k in hw/gralloc.gbm.so hw/hwcomposer.redroid.so hw/gralloc.cros.so; do
  [ -e "$BV64/$k" ] && log "base $k NEEDED: $($READELF -d "$BV64/$k" 2>/dev/null | sed -nE 's/.*\(NEEDED\).*\[(.+)\]/\1/p' | tr '\n' ' ')"
done

# 探测“我们要替换的 Mesa 库之外”是否还有 base 库 DT_NEED libLLVM（仅用于日志/决策）。
# 注意：是否移除孤儿 libLLVM 由 REMOVE_LLVM 控制，默认 0=不移除、Dockerfile 保持 COPY-only。
#   原因：reDroid 是 Android rootfs，未必有 /bin/sh（可能仅 /system/bin/sh），docker build 的
#   RUN 默认用 /bin/sh -c，缺则构建失败。移除 LLVM 只是省空间的美化项，不值得冒构建失败风险。
#   孤儿 libLLVM 无害（我们的 Mesa 库均不 DT_NEED 它，verify 第 7 项已断言）。
REPLACED_RE='libgallium_dri|libEGL_mesa|libGLESv1_CM_mesa|libGLESv2_mesa|libgbm|vulkan\.panfrost|libvulkan_panfrost|libglapi'
llvm_consumers=""
if [ -n "$(find "$BV64" -maxdepth 1 -name 'libLLVM*' 2>/dev/null)" ]; then
  while IFS= read -r so; do
    bn="$(basename "$so")"
    echo "$bn" | grep -qE "$REPLACED_RE" && continue     # 会被我们替换的，忽略
    if $READELF -d "$so" 2>/dev/null | grep -q 'libLLVM'; then llvm_consumers="$llvm_consumers $bn"; fi
  done < <(find "$BV64" "$BV64/hw" "$BV64/egl" "$BV64/dri" -maxdepth 1 -name '*.so*' -type f 2>/dev/null)
fi
if [ -n "$llvm_consumers" ]; then
  log "INFO: base 中这些非-Mesa 库仍 DT_NEED libLLVM（故无论如何都不应移除 LLVM）:$llvm_consumers"
fi
if [ "${REMOVE_LLVM:-0}" = "1" ] && [ -z "$llvm_consumers" ]; then
  REMOVE_LLVM_CMD='RUN rm -f /vendor/lib64/libLLVM*.so* && echo "[image] removed orphan libLLVM*"'
  log "REMOVE_LLVM=1 且无其它消费者 -> 构建时移除孤儿 libLLVM（需镜像内有 /bin/sh）"
else
  REMOVE_LLVM_CMD='# COPY-only（未移除孤儿 libLLVM；我们的 Mesa 栈 LLVM-free，孤儿库无害）'
  log "默认 COPY-only：不移除孤儿 libLLVM（REMOVE_LLVM=${REMOVE_LLVM:-0}）"
fi

# --- 4) inject-mesa.sh 生成 overlay 到构建上下文 -----------------------------
CTX="$WORK/ctx"; rm -rf "$CTX"; mkdir -p "$CTX"
bash "$HERE/inject-mesa.sh" "$ARM64" "$CTX/overlay" "$GPU_CONFIG"

# --- 5) 渲染 Dockerfile ------------------------------------------------------
sed -e "s#@BASE_IMAGE@#$BASE_IMAGE#g" \
    -e "s#@REMOVE_LLVM_CMD@#$REMOVE_LLVM_CMD#g" \
    "$HERE/Dockerfile.tmpl" > "$CTX/Dockerfile"
log "Dockerfile:"; sed 's/^/    | /' "$CTX/Dockerfile"
grep -q '@[A-Z_]*@' "$CTX/Dockerfile" && die "Dockerfile 仍有未替换占位符"

# --- 6) docker build ---------------------------------------------------------
log "docker build -> $OUT_IMAGE"
DOCKER_BUILDKIT=1 docker build --platform linux/arm64 -t "$OUT_IMAGE" "$CTX"

# --- 7) 导出 /vendor 校验 ----------------------------------------------------
BUILTV="$WORK/built-vendor"; rm -rf "$BUILTV"; mkdir -p "$BUILTV"
cid="$(docker create --platform linux/arm64 "$OUT_IMAGE")"
docker cp "$cid:/vendor" "$BUILTV/" 2>/dev/null || docker cp "$cid:/vendor/." "$BUILTV/" || true
docker rm "$cid" >/dev/null
log "校验镜像 /vendor ..."
bash "$HERE/verify-image.sh" "$BUILTV/vendor" | tee "$WORK/verify-image.txt"
VERIFY_RC="${PIPESTATUS[0]}"

# --- 8) docker save（可选）--------------------------------------------------
if [ "$SAVE_IMAGE" = "1" ]; then
  if have zstd; then
    SAVE="$WORK/redroid-rk3588-panthor.tar.zst"
    log "docker save | zstd -> $SAVE"; docker save "$OUT_IMAGE" | zstd -T0 -19 -o "$SAVE"
  else
    SAVE="$WORK/redroid-rk3588-panthor.tar.xz"
    log "docker save | xz -> $SAVE"; docker save "$OUT_IMAGE" | xz -T0 -6 > "$SAVE"
  fi
  log "镜像包：$SAVE ($(du -h "$SAVE" | cut -f1))"
fi

echo ""
log "==== 汇总 ===="
docker image inspect "$OUT_IMAGE" --format '  image : {{.Id}}{{"\n"}}  arch  : {{.Os}}/{{.Architecture}}{{"\n"}}  size  : {{.Size}} bytes{{"\n"}}  created: {{.Created}}'
log "verify-image 退出码=$VERIFY_RC（0=通过）"
[ "$VERIFY_RC" = "0" ] || die "镜像校验未通过，见 $WORK/verify-image.txt"
log "✅ 产出可用镜像：$OUT_IMAGE"
