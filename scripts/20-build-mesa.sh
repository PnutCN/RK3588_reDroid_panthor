#!/usr/bin/env bash
# =============================================================================
# 20-build-mesa.sh —— 交叉构建 Android arm64 Mesa
#                       (Panfrost gallium + PanVK + GBM + EGL/GLES, android platform)
# =============================================================================
# 对应移植清单 6.2：
#   [x] 选定含 Panthor KMD / G610 / AHardwareBuffer 的 Mesa commit（VERSIONS.env）
#   [x] Android arm64 启用 EGL/GLES、Gallium Panfrost、PanVK、GBM、android platform
#   [x] 与匹配的 libdrm/UAPI 同步构建（10-build-libdrm.sh 已装入 $SHIM）
#   [x] 产出 libEGL_mesa / GLES / libgallium_dri(panfrost_dri) / libvulkan_panfrost
#       / libgbm / libglapi（30-package-prebuilts.sh 落位）
#   [x] 绝不复用宿主 Ubuntu 的 Mesa .deb（本脚本全程 NDK/Bionic 交叉编译）
#
# 选项依据（均在 mesa-current/meson.options 与 meson.build 中核对过）：
#   * vulkan-drivers=panfrost  => PanVK（源码在 src/panfrost/vulkan，产物 libvulkan_panfrost.so）
#   * gallium-drivers=panfrost => Panfrost gallium（kmsro 在 26.x 已随 panfrost 内建，非独立选项）
#   * platforms=android        => 只能单独启用（meson.build:512 不允许与其它 platform 并存）
#   * gbm=enabled              => reDroid gralloc.gbm 需要 libgbm（android 属 system_has_kms_drm）
#   * egl/gles1/gles2=enabled  => libEGL_mesa / libGLESv1_CM_mesa / libGLESv2_mesa
#   * egl-lib-suffix/gles-lib-suffix=_mesa + glvnd=disabled
#                                => Android 加载器按 ro.hardware.egl=mesa dlopen libEGL_mesa.so
#                                   （meson.build:696 要求用 suffix 时必须关 glvnd）
#   * llvm=disabled            => arm64 目标驱动不链 LLVM（CLC 仅构建期代码生成，见下两条）
#   * mesa-clc=system          => 用 15-build-native-clc-tools.sh 原生产出的 host 端 mesa_clc/
#   * precomp-compiler=system     vtn_bindgen2/panfrost_compile 做构建期 libpan/*.cl 代码生成；
#                                 meson 以 find_program(native:true) 从 PATH 取用，于是
#                                 with_clc=false，上面的 -Dllvm=disabled 才成立。
#                                 （Mesa 26.3 的 panfrost/panvk 在 with_driver_using_cl 里，
#                                  不设 system 会强制 CLC→LLVM，见根 meson.build:1043-1064）
#   * expat/xmlconfig=disabled => Android 上 xmlconfig 不可用（meson.build:1934）
#   * libunwind=disabled       => meson.build:2246 对 android 有 .require(not with_platform_android)，
#                                 即 android 上 libunwind 若启用会直接 error，故必须 disabled
#   * vulkan-layers 默认即 []（不建任何 layer），无需显式传 -Dvulkan-layers=
#                                 （给带 choices 的 array 选项传空串，解析行为随 meson 版本而异，省略最稳）
#   * android-libbacktrace/libperfetto=disabled, perfetto=false, libunwind=disabled
#                                => 去掉 backtrace/perfetto/libunwind 依赖（meson.build:2247
#                                   明确 Android 用 backtrace 而非 libunwind；此处都不引）
#
# 环境变量：
#   ANDROID_STUB=1   -Dandroid-stub=true，用 mesa 自带 android_stub 头/stub库（纯 NDK 独立构建的
#                    标准生产路径；默认值。stub .so 仅链接期用、不入产物，运行期由设备真实库解析）
#   ANDROID_STUB=0   -Dandroid-stub=false，链接真实 AOSP cutils/hardware/... 头（需自备 AOSP 头 sysroot）
#   GALLIUM_DRIVERS  覆盖 gallium 驱动列表（默认 panfrost；可加 softpipe 做软件回退）
#   VULKAN_DRIVERS   覆盖 vulkan 驱动列表（默认 panfrost=PanVK）
#   BUILDTYPE        默认 release
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

need meson
need ninja
resolve_ndk

MESA_SRC="${MESA_SRC_DIR:-$SRC/mesa}"
[ -f "$MESA_SRC/meson.build" ] || die "缺 Mesa 源码：先跑 scripts/00-fetch-sources.sh（或设 MESA_SRC_DIR）"
[ -f "$CROSS_FILE" ]           || die "缺 cross-file：先跑 scripts/gen-android-sysroot.sh"
[ -f "$SHIM_PC/libdrm.pc" ]    || die "缺 libdrm.pc：先跑 scripts/10-build-libdrm.sh"

# Mesa 构建期需要宿主 python + mako（pan_packers / vulkan entrypoints 代码生成）
python3 -c 'import mako' 2>/dev/null || die "缺 python3-mako（Mesa 代码生成需要）：apt install python3-mako / pip install mako"

# ---- Path A：复用 15-build-native-clc-tools.sh 原生产出的 CLC 代码生成工具 ----
# 交叉构建用 -Dmesa-clc=system/-Dprecomp-compiler=system 时，meson 以
# find_program(native:true) 从 PATH 找 mesa_clc/vtn_bindgen2/panfrost_compile。
# 这三个是 host(x86_64) 工具，在构建期把 libpan/*.cl 编成 SPIR-V→C/NIR 嵌进 arm64 驱动。
[ -d "$NATIVE_TOOLS_BIN" ] && export PATH="$NATIVE_TOOLS_BIN:$PATH"
for t in mesa_clc vtn_bindgen2 panfrost_compile; do
  command -v "$t" >/dev/null 2>&1 \
    || die "缺原生工具 $t：先跑 scripts/15-build-native-clc-tools.sh（应装到 $NATIVE_TOOLS_BIN）"
done
log "原生 CLC 工具就位：$(command -v mesa_clc) / $(command -v vtn_bindgen2) / $(command -v panfrost_compile)"

GALLIUM_DRIVERS="${GALLIUM_DRIVERS:-panfrost}"
VULKAN_DRIVERS="${VULKAN_DRIVERS:-panfrost}"
BUILDTYPE="${BUILDTYPE:-release}"
ANDROID_STUB="${ANDROID_STUB:-1}"   # 默认 stub=true（CI push 路线即此；run #8 已验证含 Panthor）
if [ "$ANDROID_STUB" = "1" ]; then ANDROID_STUB_OPT=true; else ANDROID_STUB_OPT=false; fi

# 安装布局对齐设备 /vendor/lib64（DESTDIR 暂存到 $STAGE）
PREFIX=/vendor
LIBDIR=lib64
DRI_PATH="$PREFIX/$LIBDIR/dri"
ICD_PATH="$PREFIX/etc/vulkan/icd.d"

BUILD="$MESA_SRC/build-android-${TARGET_ARCH}"
log "配置 Mesa 交叉构建 -> $BUILD"
log "  gallium-drivers=$GALLIUM_DRIVERS  vulkan-drivers=$VULKAN_DRIVERS  android-stub=$ANDROID_STUB_OPT"
rm -rf "$BUILD"

# --wrap-mode=nofallback：**不给缺失的依赖下载 subproject**。
#
# 加 freedreno 支持时撞到的：Mesa 的 src/freedreno/meson.build 里
#   dep_libarchive = dependency('libarchive', allow_fallback: true,
#                               required: false, disabler: true)
# —— 它本身是可选的（找不到就把 crashdec/cffdump 这些 decode 工具关掉），
# 但 allow_fallback 会让 meson 先去下 libarchive 3.7.2 的源码，而那份源码
# 交叉编译到 Android 时挂在 `archive.h:101 'android_lf.h' file not found`
# （run 35223325269，编到 689/1580 才炸）。
#
# 禁掉 fallback 之后它老老实实报 not found，disabler 生效，驱动照编。
# libdrm 不受影响 —— 这条流水线是 10-build-libdrm.sh 自己编好再喂进来的，
# 本来就不靠 fallback。
meson setup "$BUILD" "$MESA_SRC" \
  --wrap-mode=nofallback \
  --cross-file="$CROSS_FILE" \
  --prefix="$PREFIX" \
  --libdir="$LIBDIR" \
  --buildtype="$BUILDTYPE" \
  -Dplatforms=android \
  -Dplatform-sdk-version="$PLATFORM_SDK_VERSION" \
  -Dandroid-strict=true \
  -Dandroid-stub="$ANDROID_STUB_OPT" \
  -Dandroid-libbacktrace=disabled \
  -Dandroid-libperfetto=disabled \
  -Dperfetto=false \
  -Dgallium-drivers="$GALLIUM_DRIVERS" \
  -Dvulkan-drivers="$VULKAN_DRIVERS" \
  -Dgbm=enabled \
  -Degl=enabled \
  -Dgles1=enabled \
  -Dgles2=enabled \
  -Dglvnd=disabled \
  -Degl-lib-suffix=_mesa \
  -Dgles-lib-suffix=_mesa \
  -Dllvm=disabled \
  -Dmesa-clc=system \
  -Dprecomp-compiler=system \
  -Dcpp_rtti=false \
  -Dglx=disabled \
  -Dexpat=disabled \
  -Dxmlconfig=disabled \
  -Dlibunwind=disabled \
  -Dgallium-va=disabled \
  -Dbuild-tests=false \
  -Ddri-drivers-path="$DRI_PATH" \
  -Dvulkan-icd-dir="$ICD_PATH"

log "编译 Mesa（ninja）"
ninja -C "$BUILD"

log "安装到 DESTDIR=$STAGE（prefix=$PREFIX libdir=$LIBDIR）"
rm -rf "$STAGE"
DESTDIR="$STAGE" ninja -C "$BUILD" install

# ---- 产物存在性快检（详细校验在 40-verify-panthor.sh）----
# 依据 Mesa 26.3(commit 25b4dfa) 源码核对，Android 下产物名/位置与桌面不同，勿写死：
#   * gbm：platform-sdk-version>=30 => 名为 libgbm_mesa.so.1.0.0（src/gbm/meson.build:20）
#   * libgallium_dri.so：无版本，shared_library 无 install_dir => 落在 $libdir 根（非 $libdir/dri）
#     （src/gallium/targets/dri/meson.build:36-69；dri-drivers-path 仅用于 summary 显示）
#   * libEGL_mesa/libGLESv2_mesa/libvulkan_panfrost：均在 $libdir 根（egl-lib-suffix/gles-lib-suffix）
STAGE_LIB="$STAGE$PREFIX/$LIBDIR"
expect_found() { find "$1" -name "$2" 2>/dev/null | grep -q . || die "预期产物缺失：$2（$3）"; }
expect_found "$STAGE"     'libgallium_dri.so' "gallium megadriver 未构建"
expect_found "$STAGE_LIB" 'libgbm*.so*'       "GBM 未构建（android 名应为 libgbm_mesa.so*）"
ls "$STAGE_LIB"/libEGL_mesa.so*        >/dev/null 2>&1 || die "缺 libEGL_mesa.so（egl-lib-suffix 未生效？）"
ls "$STAGE_LIB"/libGLESv2_mesa.so*     >/dev/null 2>&1 || die "缺 libGLESv2_mesa.so"
# **按 $VULKAN_DRIVERS 查，不要写死 panfrost**：这条流水线加 freedreno（turnip）
# 支持之后，产物叫 libvulkan_freedreno.so，而写死的检查会在 Mesa 编完
# 1387/1387 之后才报「缺 libvulkan_panfrost.so（PanVK 未构建？）」——
# 那句话指向 PanVK，而实际上根本没让它编 PanVK（run 35224443431）。
for _vk in ${VULKAN_DRIVERS//,/ }; do
  ls "$STAGE_LIB"/libvulkan_${_vk}.so* >/dev/null 2>&1 \
    || die "缺 libvulkan_${_vk}.so（vulkan-drivers=$VULKAN_DRIVERS，这一项没构建？）"
done

log "Mesa 构建完成。产物根：$STAGE_LIB"
log "下一步：scripts/30-package-prebuilts.sh（落位 device_redroid-prebuilts 布局）"
