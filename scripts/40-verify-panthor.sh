#!/usr/bin/env bash
# =============================================================================
# 40-verify-panthor.sh —— 校验产物确含 Panthor KMD、ABI 正确、依赖干净
# =============================================================================
# 直接落实移植清单 6.2 第 6 条（line 270）：
#   “在构建产物上用 readelf/strings 确认包含 panthor KMD，而不是仅看到旧的
#    panfrost_kmod。”
#
# 判据（依据 mesa-current 源码核对）：
#   * pan_kmod.c 分派表同时含 "panfrost"(line23) 与 "panthor"(line27) 两个字符串，
#     并对内核驱动名做 strcmp。含 Panthor 后端的产物 .rodata 必出现独立 "panthor"。
#   * panthor_kmod.c 的错误串（"panthor_kmod ...", "drm_panthor_..."）在 .rodata。
#   * 未 strip 时符号表含 panthor_kmod_ops / panthor_kmod_dev_create 等。
#   * DRM_IOCTL_PANTHOR_* 通过 libdrm 的 drmIoctl 发出 => DT_NEEDED 必有 libdrm.so.2。
#   * -Dllvm=disabled => 绝不应出现 libLLVM*。宿主 glibc 库也不应出现。
#
# 用法：scripts/40-verify-panthor.sh [prebuilts_arm64_dir]
#       默认 $OUT/prebuilts/arm64（30-package-prebuilts.sh 的产物）
# 退出码：0=全部 PASS；1=有 FAIL。
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

need readelf
need strings

DST="${1:-$OUT/$PREBUILT_LAYOUT_ARM64}"
[ -d "$DST" ] || die "产物目录不存在：$DST（先跑 30-package-prebuilts.sh）"

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
wrn()  { WARN=$((WARN+1)); printf '  \033[1;33mWARN\033[0m %s\n' "$*"; }

DRI="$DST/lib/dri/libgallium_dri.so"
VK="$DST/lib/hw/libvulkan_panfrost.so"
EGL="$(ls "$DST"/lib/egl/libEGL_mesa.so* 2>/dev/null | head -1)"

echo "==================== 1. 产物存在性 ===================="
for f in "$DRI" "$VK" "$EGL" "$DST/lib/libgbm.so.1" "$DST/lib/libdrm.so.2"; do
  if [ -e "$f" ]; then ok "存在 $(basename "$f")"; else bad "缺失 $f"; fi
done
[ -e "$DST/lib/dri/panfrost_dri.so" ] && ok "存在 panfrost_dri.so（gallium 驱动软链）" \
  || bad "缺 panfrost_dri.so 软链（Android.mk 靠 find -type l 识别）"

echo "==================== 2. ELF ABI（必须 arm64/Bionic）===================="
check_elf() {
  local f="$1"; [ -e "$f" ] || { bad "跳过 ABI（不存在）：$f"; return; }
  local hdr; hdr="$(readelf -h "$f")"
  local class mach typ
  class="$(echo "$hdr" | awk -F: '/Class:/{gsub(/^ +/,"",$2);print $2}')"
  mach="$(echo "$hdr"  | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}')"
  typ="$(echo "$hdr"   | awk -F: '/Type:/{gsub(/^ +/,"",$2);print $2}')"
  local name; name="$(basename "$f")"
  case "$class" in *ELF64*) ok "$name: ELF64";; *) bad "$name: Class=$class（应 ELF64）";; esac
  case "$mach"  in *AARCH64*|*aarch64*) ok "$name: Machine=AArch64";; *) bad "$name: Machine=$mach（应 AArch64，疑似宿主架构泄漏）";; esac
  case "$typ"   in *DYN*) ok "$name: Type=DYN(共享对象)";; *) wrn "$name: Type=$typ";; esac
}
check_elf "$DRI"; check_elf "$VK"; check_elf "$EGL"; check_elf "$DST/lib/libgbm.so.1"

echo "==================== 3. Panthor KMD（清单 6.2 line270 核心）===================="
check_panthor() {
  local f="$1"; local name; name="$(basename "$f")"
  [ -e "$f" ] || { bad "跳过 panthor 校验（不存在）：$f"; return; }
  # 3a. .rodata 里的独立 "panthor" 驱动名（分派表 strcmp 用）——即便 strip 也在
  if strings -a "$f" | grep -qx 'panthor'; then
    ok "$name: 含独立字符串 \"panthor\"（KMD 分派表）"
  else
    bad "$name: 未找到独立 \"panthor\" 字符串 —— 可能只编进了旧 panfrost_kmod"
  fi
  # 3b. panthor_kmod 的实现串/结构名
  local nk; nk="$(strings -a "$f" | grep -c 'panthor_kmod' || true)"
  if [ "${nk:-0}" -gt 0 ]; then ok "$name: 含 panthor_kmod* 字符串 x$nk"; else wrn "$name: 无 panthor_kmod* 串（可能被内联/精简）"; fi
  # 3c. 符号表（未 strip 时）：panthor_kmod_ops / panthor_kmod_dev_create
  if readelf -sW "$f" 2>/dev/null | grep -qE 'panthor_kmod_ops|panthor_kmod_dev_create'; then
    ok "$name: 符号表含 panthor_kmod_ops/dev_create"
  else
    wrn "$name: 符号表未见 panthor_kmod_*（若已 strip 属正常，以字符串判据为准）"
  fi
  # 3d. 反向确认：不能“只有 panfrost 没有 panthor”
  if strings -a "$f" | grep -qx 'panfrost' && ! strings -a "$f" | grep -qx 'panthor'; then
    bad "$name: 只有 \"panfrost\" 而无 \"panthor\" —— 正是清单警告的旧 KMD 情形"
  fi
}
check_panthor "$DRI"
check_panthor "$VK"

echo "==================== 4. DT_NEEDED 依赖洁净度 ===================="
check_needed() {
  local f="$1"; local name; name="$(basename "$f")"
  [ -e "$f" ] || { bad "跳过 NEEDED（不存在）：$f"; return; }
  local needed; needed="$(readelf -dW "$f" | awk -F'[][]' '/NEEDED/{print $2}' | tr '\n' ' ')"
  printf '      %s NEEDED: %s\n' "$name" "$needed"
  # 必须有 libdrm（panthor ioctl 经 drmIoctl）
  echo "$needed" | grep -q 'libdrm\.so' && ok "$name: 依赖 libdrm.so*" || bad "$name: 未依赖 libdrm（panthor ioctl 无从发出）"
  # 绝不能有 LLVM（我们 -Dllvm=disabled）
  echo "$needed" | grep -qi 'libLLVM' && bad "$name: 依赖 libLLVM（应 -Dllvm=disabled）" || ok "$name: 无 libLLVM 依赖"
  # 绝不能有宿主 glibc 专有库（Bionic 无这些 SONAME）
  for glibc in libpthread.so.0 librt.so.1 libdl.so.2 libm.so.6 ld-linux; do
    echo "$needed" | grep -q "$glibc" && bad "$name: 出现 glibc 专有依赖 $glibc（疑似误用宿主工具链）"
  done
  ok "$name: 未见 glibc 专有 SONAME"
}
check_needed "$DRI"; check_needed "$VK"; check_needed "$EGL"

echo "==================== 5. GBM 导出符号（gralloc.gbm 需要）===================="
if [ -e "$DST/lib/libgbm.so.1" ]; then
  for sym in gbm_create_device gbm_bo_create gbm_bo_get_fd gbm_surface_create; do
    readelf -sW "$DST/lib/libgbm.so.1" 2>/dev/null | grep -q "$sym" \
      && ok "libgbm 导出 $sym" || wrn "libgbm 未见 $sym（可能版本差异/已 strip）"
  done
fi

echo "==================== 汇总 ===================="
printf '  PASS=%d  FAIL=%d  WARN=%d\n' "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ 校验通过：产物为 arm64/Bionic，含 Panthor KMD，依赖洁净。"
  exit 0
else
  echo "  ❌ 存在 FAIL 项，勿用于打包/上板。"
  exit 1
fi
