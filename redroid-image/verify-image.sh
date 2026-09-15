#!/usr/bin/env bash
# =============================================================================
# verify-image.sh —— 校验“注入 Mesa 后”的 reDroid 镜像 /vendor 目录（从构建好的镜像
#                    docker cp 出来），出具 PASS/FAIL 汇总。高信号、低噪声。
# =============================================================================
# 用法：verify-image.sh <exported_vendor_dir>
#   exported_vendor_dir : 镜像内 /vendor 的导出副本（含 lib64/ 与 bin/gpu_config.sh）
#
# 校验项：
#   1. 必需文件存在（egl/libEGL_mesa.so、dri/libgallium_dri.so、hw/vulkan.panfrost.so、
#      libgbm.so.1、libdrm.so、libc++_shared.so）
#   2. 全部为 ELF64 / AArch64（arm64/Bionic，不是宿主 glibc 库）
#   3. Panthor KMD 证据：libgallium_dri.so 与 vulkan.panfrost.so 含 "panthor" 与 panthor_kmod*
#   4. libgbm.so.1 的 SONAME 恰为 libgbm.so.1（patchelf 生效）；libdrm.so SONAME=libdrm.so
#   5. gpu_config.sh 含 panthor 检测
#   6. 【关键】上游保留二进制(gralloc.gbm.so / hwcomposer.redroid.so / gralloc.cros.so)的
#      DT_NEEDED 中，凡属 Mesa/libdrm/GBM/LLVM 家族者，必须能在本 /vendor/lib64 树里按名解析到；
#      这直接验证“drop-in 替换”前提是否成立（命名/版本对齐）。
#   7. 我们的 Mesa 库不得 DT_NEED libLLVM*（确认 LLVM-free）
# =============================================================================
set -uo pipefail

V="${1:-}"
[ -n "$V" ] && [ -d "$V/lib64" ] || { echo "用法：verify-image.sh <exported_vendor_dir>（需含 lib64/）" >&2; exit 2; }
L64="$V/lib64"

READELF="$(command -v readelf || command -v llvm-readelf || true)"
[ -n "$READELF" ] || { echo "缺 readelf" >&2; exit 2; }

PASS=0; FAIL=0
ok()   { echo -e "  \033[1;32mPASS\033[0m $*"; PASS=$((PASS+1)); }
bad()  { echo -e "  \033[1;31mFAIL\033[0m $*"; FAIL=$((FAIL+1)); }
info() { echo      "      $*"; }

# 在 /vendor/lib64 树里按名解析一个 DT_NEEDED 名（含子目录 egl/dri/hw；跟随软链）
resolve_in_vendor() {
  local need="$1" p
  for p in "$L64/$need" "$L64/egl/$need" "$L64/dri/$need" "$L64/hw/$need"; do
    [ -e "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}
needed_list() { $READELF -d "$1" 2>/dev/null | sed -nE 's/.*\(NEEDED\).*\[(.+)\]/\1/p'; }
soname_of()   { $READELF -d "$1" 2>/dev/null | sed -nE 's/.*\(SONAME\).*\[(.+)\]/\1/p' | head -1; }
is_arm64()    { $READELF -h "$1" 2>/dev/null | grep -q 'Machine:.*AArch64'; }

echo "==================== 1. 注入文件存在性 ===================="
declare -A REQ=(
  ["egl/libEGL_mesa.so"]=1 ["egl/libGLESv2_mesa.so"]=1
  ["dri/libgallium_dri.so"]=1 ["dri/panfrost_dri.so"]=1
  ["hw/vulkan.panfrost.so"]=1
  ["libgbm.so.1"]=1 ["libgbm.so.1.0.0"]=1 ["libdrm.so"]=1 ["libc++_shared.so"]=1
)
for f in "${!REQ[@]}"; do
  if [ -e "$L64/$f" ]; then ok "存在 $f"; else bad "缺失 $f"; fi
done

echo "==================== 2. ELF ABI（必须 arm64/Bionic）===================="
for f in egl/libEGL_mesa.so dri/libgallium_dri.so hw/vulkan.panfrost.so libgbm.so.1.0.0 libdrm.so; do
  p="$(resolve_in_vendor "$f" || true)"; [ -n "$p" ] || continue
  if is_arm64 "$p"; then ok "$f: AArch64"; else bad "$f: 非 AArch64（误入宿主库？）"; fi
done

echo "==================== 3. Panthor KMD（核心）===================="
for f in dri/libgallium_dri.so hw/vulkan.panfrost.so; do
  p="$(resolve_in_vendor "$f" || true)"; [ -n "$p" ] || { bad "$f 不存在，无法验 panthor"; continue; }
  n_panthor="$(strings -a "$p" 2>/dev/null | grep -cw 'panthor' || true)"
  n_kmod="$(strings -a "$p" 2>/dev/null | grep -c 'panthor_kmod' || true)"
  if [ "${n_panthor:-0}" -ge 1 ]; then ok "$f: 含独立字符串 \"panthor\" x$n_panthor"; else bad "$f: 未见 \"panthor\""; fi
  if [ "${n_kmod:-0}" -ge 1 ]; then ok "$f: 含 panthor_kmod* x$n_kmod"; else bad "$f: 未见 panthor_kmod*"; fi
done

echo "==================== 4. SONAME 对齐 ===================="
if [ -e "$L64/libgbm.so.1.0.0" ]; then
  s="$(soname_of "$L64/libgbm.so.1.0.0")"
  if [ "$s" = "libgbm.so.1" ]; then ok "libgbm.so.1.0.0 SONAME=libgbm.so.1（上游 gralloc.gbm.so 可解析）"; else bad "libgbm SONAME=$s（期望 libgbm.so.1）"; fi
fi
if [ -e "$L64/libdrm.so" ]; then
  s="$(soname_of "$L64/libdrm.so")"
  if [ "$s" = "libdrm.so" ]; then ok "libdrm.so SONAME=libdrm.so"; else bad "libdrm SONAME=$s（期望 libdrm.so）"; fi
fi

echo "==================== 5. gpu_config.sh panthor 检测 ===================="
if [ -f "$V/bin/gpu_config.sh" ]; then
  if grep -q 'panthor' "$V/bin/gpu_config.sh"; then ok "/vendor/bin/gpu_config.sh 含 panthor 检测"; else bad "gpu_config.sh 不含 panthor"; fi
  if grep -Eq 'ro\.hardware\.egl[[:space:]]+mesa' "$V/bin/gpu_config.sh"; then ok "gpu_config.sh 设 ro.hardware.egl=mesa"; else bad "gpu_config.sh 未设 egl=mesa"; fi
else
  bad "/vendor/bin/gpu_config.sh 缺失"
fi

echo "==================== 6. 上游保留二进制的 Mesa 依赖可解析（drop-in 前提）===================="
# 只针对 Mesa/libdrm/GBM/LLVM 家族名做硬校验；系统库(liblog/libutils/...)默认在 /system 存在，不在此校验。
mesa_family() { case "$1" in libgbm*|libdrm*|libLLVM*|libgallium*|libc++_shared*|libEGL_*|libGLESv*|libvulkan_*|vulkan.*|libglapi*) return 0;; *) return 1;; esac; }
KEPT="$(find "$L64/hw" -maxdepth 1 \( -name 'gralloc.*.so' -o -name 'hwcomposer.redroid.so' -o -name 'audio.primary.redroid.so' \) -type f 2>/dev/null)"
if [ -z "$KEPT" ]; then
  info "（未在 /vendor/lib64/hw 找到 gralloc.*/hwcomposer.redroid.so；可能 base 布局不同，跳过）"
else
  for k in $KEPT; do
    kn="$(basename "$k")"; unresolved=""
    while read -r nd; do
      [ -n "$nd" ] || continue
      mesa_family "$nd" || continue
      resolve_in_vendor "$nd" >/dev/null || unresolved="$unresolved $nd"
    done < <(needed_list "$k")
    if [ -z "$unresolved" ]; then ok "$kn 的 Mesa 系依赖均可在 /vendor/lib64 解析"; else bad "$kn 未解析依赖:$unresolved"; fi
    info "$kn NEEDED(mesa系): $(needed_list "$k" | grep -E 'libgbm|libdrm|libLLVM|libgallium|libc\+\+_shared|libEGL_|libGLESv|vulkan' | tr '\n' ' ')"
  done
fi

echo "==================== 7. 我们的 Mesa 库 LLVM-free ===================="
for f in dri/libgallium_dri.so egl/libEGL_mesa.so hw/vulkan.panfrost.so libgbm.so.1.0.0; do
  p="$(resolve_in_vendor "$f" || true)"; [ -n "$p" ] || continue
  if needed_list "$p" | grep -q 'libLLVM'; then bad "$f 仍 DT_NEED libLLVM"; else ok "$f 无 libLLVM 依赖"; fi
done

echo "==================== 汇总 ===================="
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  \033[1;32m✅ 镜像校验通过：Mesa/PanVK/GBM 已按上游命名注入，含 Panthor KMD，drop-in 依赖闭合。\033[0m"
  exit 0
else
  echo -e "  \033[1;31m❌ 有 $FAIL 项未过；见上。\033[0m"
  exit 1
fi
