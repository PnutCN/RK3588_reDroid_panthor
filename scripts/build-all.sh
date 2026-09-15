#!/usr/bin/env bash
# =============================================================================
# build-all.sh —— 一键跑完整条 Android Mesa+PanVK+GBM 交叉构建流水线
# =============================================================================
# 顺序：取源 -> 生成 sysroot/cross-file -> libdrm -> Mesa -> 打包 -> 校验
# 任一步失败即停（set -e）。各步幂等，可单独重跑。
#
# 常用：
#   ./build-all.sh                 # 默认(ANDROID_STUB=1)：mesa android_stub 纯 NDK 独立构建（生产可用，run #8 已验证）
#   ANDROID_STUB=0 ./build-all.sh  # full：链接真实 AOSP 头（需自备完整 AOSP 头 sysroot，含 system/graphics.h）
#   WORK=/big/disk ./build-all.sh  # 指定大容量工作目录
#   GALLIUM_DRIVERS=panfrost,softpipe ./build-all.sh   # 加软件回退
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

STEPS="${STEPS:-fetch sysroot libdrm nativeclc mesa package verify}"
run_step() {
  local s="$1"; shift
  log "======== 步骤：$s ========"
  "$@"
}

for step in $STEPS; do
  case "$step" in
    fetch)    run_step "00 取源"        bash "$HERE/00-fetch-sources.sh" ;;
    sysroot)  run_step "05 sysroot"     bash "$HERE/gen-android-sysroot.sh" ;;
    libdrm)   run_step "10 libdrm"      bash "$HERE/10-build-libdrm.sh" ;;
    nativeclc) run_step "15 native-clc" bash "$HERE/15-build-native-clc-tools.sh" ;;
    mesa)     run_step "20 mesa"        bash "$HERE/20-build-mesa.sh" ;;
    package)  run_step "30 打包"        bash "$HERE/30-package-prebuilts.sh" ;;
    verify)   run_step "40 校验"        bash "$HERE/40-verify-panthor.sh" ;;
    *) die "未知步骤：$step（可用：fetch sysroot libdrm nativeclc mesa package verify）" ;;
  esac
done

log "全部完成。产物：${PREBUILTS_DST:-$OUT/$PREBUILT_LAYOUT_ARM64}"
log "把该目录内容并入 device_redroid-prebuilts/prebuilts/arm64/（保留其 gralloc.gbm/HWC 等原样），"
log "再按 upstream 流程编 LineageOS 20 / reDroid 镜像即可（清单 6.1/6.3）。"
