#!/usr/bin/env bash
# =============================================================================
# 15-build-native-clc-tools.sh —— 在 host(x86_64) 上原生构建 Mesa 的 CLC 代码生成工具
# =============================================================================
# 为什么需要（对应 run #5 的 "Feature llvm cannot be disabled: CLC requires LLVM"）：
#   Mesa 26.3(commit 25b4dfa) 根 meson.build 把 panfrost gallium / panvk 列进了
#   with_driver_using_cl，于是 with_clc=true，再 with_llvm.enable_if(with_clc) 强制
#   启用 LLVM —— 交叉构建里的 -Dllvm=disabled 因此在 setup 阶段直接被拒。
#
#   但追进源码可见，CLC 只是【构建期代码生成】：panfrost 的内部着色器库
#   src/panfrost/libpan/*.cl（OpenCL C）在构建时由
#       mesa_clc(clang/LLVM) -> .spv -> vtn_bindgen2 / panfrost_compile -> C/NIR
#   编译后【嵌进】驱动（src/panfrost/libpan/meson.build 的 custom_target）。
#   最终交叉编出的 arm64 驱动【不链接】任何 LLVM/libmesaclc —— 整个 panfrost 树
#   grep libmesaclc/dep_clc 为 0 处。故 LLVM 只是构建主机的临时需求。
#
# 解法（Mesa 为交叉编译预留的标准逃生口，见根 meson.build:1052 / clc,spirv meson.build）：
#   1) 本脚本：在 host x86_64 上【原生】编出三个工具，装到 $NATIVE_TOOLS/bin：
#        mesa_clc        —— -Dmesa-clc=enabled + -Dinstall-mesa-clc=true 触发
#        vtn_bindgen2    —— 同上（install-mesa-clc 一并安装）
#        panfrost_compile—— -Dprecomp-compiler=enabled + -Dinstall-precomp-compiler=true，
#                           并由 -Dtools=panfrost 触发 src/meson.build:104 进入 src/panfrost
#   2) 20-build-mesa.sh：交叉构建时加 -Dmesa-clc=system -Dprecomp-compiler=system，
#      meson 用 find_program(native:true) 从 PATH 取这三个现成工具，于是
#      with_clc=false、-Dllvm=disabled 成立，arm64 驱动保持精简无 LLVM。
#
# host 依赖（GitHub ubuntu-24.04 apt，见 .github/workflows/android-mesa.yml）：
#   llvm-18-dev libclang-18-dev libclang-cpp18-dev clang-18
#   libllvmspirvlib-18-dev   (= LLVMSPIRVLib，版本须与 LLVM 主.次一致，见 meson.build:2085)
#   SPIRV-Tools (>= 2024.1，见 meson.build:2099)：Ubuntu noble 无 dev 包（spirv-tools 源码包
#     只产 CLI，无 libspirv-tools-dev/spirv-tools-dev），故本脚本用 cmake 从源码构建【静态】库。
#   libdrm-dev               (tools=panfrost 的 bifrost_compiler/panfrost 工具需 dep_libdrm)
# 说明：
#   * 不需要 libclc —— dep_clc 仅在 rusticl/microsoft-clc 时才要(meson.build:1072)；
#     这里用 -Dtools=panfrost（非驱动）+ -Dmicrosoft-clc=disabled，mesa_clc 不依赖 libclc。
#   * -Dshared-llvm=enabled + libclang-cpp18-dev => dep_clang 走 libclang-cpp.so(meson.build:2112)，
#     不必逐个找 clangBasic/clangAST/... 模块。
#   * cpp_rtti 必须与 host LLVM 的 RTTI 一致(meson.build:2051-2056)，脚本运行时探测。
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

need meson
need ninja

MESA_SRC="${MESA_SRC_DIR:-$SRC/mesa}"
[ -f "$MESA_SRC/meson.build" ] || die "缺 Mesa 源码：先跑 scripts/00-fetch-sources.sh"

# 幂等：三个工具都在就跳过（重复跑 build-all 时省时间）
if [ -x "$NATIVE_TOOLS_BIN/mesa_clc" ] && [ -x "$NATIVE_TOOLS_BIN/vtn_bindgen2" ] \
   && [ -x "$NATIVE_TOOLS_BIN/panfrost_compile" ]; then
  log "原生 CLC 工具已存在，跳过构建：$NATIVE_TOOLS_BIN"
  exit 0
fi

# ---- 选定 host LLVM（noble 默认 18；LLVMSPIRVLib 须与其主.次版本一致）--------
LLVM_CONFIG="$(command -v llvm-config-18 || command -v llvm-config || true)"
[ -n "$LLVM_CONFIG" ] || die "缺 llvm-config（apt install llvm-18-dev）"
log "host LLVM = $("$LLVM_CONFIG" --version) via $LLVM_CONFIG"

# Mesa 要求 cpp_rtti 与 LLVM 的 RTTI 设置一致，否则 meson.build:2051-2056 直接 error
RTTI=false
case "$("$LLVM_CONFIG" --has-rtti 2>/dev/null || echo NO)" in
  YES|yes|ON|on|TRUE|true) RTTI=true ;;
esac
log "host LLVM --has-rtti -> -Dcpp_rtti=$RTTI"

# LLVMSPIRVLib.pc 常落在 /usr/lib/llvm-18/lib/pkgconfig（非 pkg-config 默认搜索路径），
# 补进 PKG_CONFIG_PATH，否则 meson 报 "Dependency LLVMSPIRVLib not found"。
SPV_PC="$(find /usr/lib /usr/lib64 -name 'LLVMSPIRVLib.pc' 2>/dev/null | head -1)"
if [ -n "$SPV_PC" ]; then
  export PKG_CONFIG_PATH="$(dirname "$SPV_PC")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  log "PKG_CONFIG_PATH += $(dirname "$SPV_PC")（LLVMSPIRVLib.pc）"
else
  warn "未找到 LLVMSPIRVLib.pc（apt install libllvmspirvlib-18-dev？）；meson 或将报缺 LLVMSPIRVLib"
fi

# ---- SPIRV-Tools（dev）：Ubuntu noble 不提供 SPIRV-Tools 的 dev 包 ------------------
#   spirv-tools 源码包只产 CLI(spirv-tools)，无 libspirv-tools-dev/spirv-tools-dev（全套件皆无，
#   run #7 已证实）。而 mesa_clc 硬依赖 SPIRV-Tools.pc(>=2024.1)（root meson.build:2096-2102）。
#   故用 cmake 从源码构建【静态】库：静态 => mesa_clc 运行期无需再找 libSPIRV-Tools.so，
#   交叉构建阶段直接从 PATH 调用即可，省掉 LD_LIBRARY_PATH 之类脆弱处理。
SPV_TAG="${SPIRV_TOOLS_TAG:-v2025.1}"
SPV_PREFIX="$WORK/spirv-tools-install"
# .pc 依发行版/cmake 版本可能落在 lib/ 或 lib/x86_64-linux-gnu/，统一探测后加进 PKG_CONFIG_PATH
_spv_pcdirs() {
  local d
  for d in "$SPV_PREFIX/lib/pkgconfig" "$SPV_PREFIX/lib/x86_64-linux-gnu/pkgconfig" "$SPV_PREFIX/lib64/pkgconfig"; do
    [ -d "$d" ] && printf '%s:' "$d"
  done
}
if ! PKG_CONFIG_PATH="$(_spv_pcdirs)$PKG_CONFIG_PATH" pkg-config --exists 'SPIRV-Tools >= 2024.1' 2>/dev/null; then
  need cmake
  need git
  SPV_SRC="$WORK/spirv-tools-src"
  HDR_DIR="$WORK/spirv-headers"
  log "构建 SPIRV-Tools ($SPV_TAG, 静态) -> $SPV_PREFIX"
  rm -rf "$SPV_SRC" "$HDR_DIR"
  git clone --depth 1 --branch "$SPV_TAG" https://github.com/KhronosGroup/SPIRV-Tools.git "$SPV_SRC"
  # SPIRV_SKIP_TESTS=ON 下 external/CMakeLists.txt 只需 SPIRV-Headers（googletest/effcee/re2/abseil
  # 均被 SKIP_TESTS 门控跳过），故无需 git-sync-deps（该脚本在 v2025.1 已改名/移除），
  # 按 DEPS 的精确 sha 拉 headers，并用 -DSPIRV-Headers_SOURCE_DIR 指定，避开 external/spirv-headers 路径歧义。
  HDR_REV="$(sed -nE "s/^[[:space:]]*'spirv_headers_revision'[[:space:]]*:[[:space:]]*'([0-9a-fA-F]+)'.*/\1/p" "$SPV_SRC/DEPS" | head -1)"
  [ -n "$HDR_REV" ] || die "无法从 $SPV_SRC/DEPS 解析 spirv_headers_revision"
  log "SPIRV-Headers @ $HDR_REV -> $HDR_DIR"
  git init -q "$HDR_DIR"
  git -C "$HDR_DIR" fetch --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git "$HDR_REV"
  git -C "$HDR_DIR" checkout -q FETCH_HEAD
  cmake -S "$SPV_SRC" -B "$SPV_SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SPV_PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSPIRV_SKIP_TESTS=ON \
    -DSPIRV-Headers_SOURCE_DIR="$HDR_DIR"
  cmake --build "$SPV_SRC/build" -j"$(nproc)"
  cmake --install "$SPV_SRC/build"
fi
export PKG_CONFIG_PATH="$(_spv_pcdirs)$PKG_CONFIG_PATH"
if pkg-config --exists 'SPIRV-Tools >= 2024.1' 2>/dev/null; then
  log "SPIRV-Tools dev 就绪：$(pkg-config --modversion SPIRV-Tools)"
else
  die "SPIRV-Tools.pc 仍不可达（检查上面 cmake 构建日志 / PKG_CONFIG_PATH=$PKG_CONFIG_PATH）"
fi

# ---- native-file：固定 llvm-config-18 + clang-18，避免误选 runner 上其它 LLVM ----
NATIVE_INI="$WORK/native-clc.ini"
{
  echo "[binaries]"
  command -v clang-18   >/dev/null 2>&1 && echo "c = 'clang-18'"
  command -v clang++-18 >/dev/null 2>&1 && echo "cpp = 'clang++-18'"
  echo "llvm-config = '$(basename "$LLVM_CONFIG")'"
} > "$NATIVE_INI"
log "native-file -> $NATIVE_INI"; sed 's/^/  /' "$NATIVE_INI" >&2

NATIVE_BUILD="$WORK/build-native-clc"
log "配置 Mesa 原生工具构建 -> $NATIVE_BUILD"
rm -rf "$NATIVE_BUILD"

# 只编工具、不编任何目标驱动/平台（gallium/vulkan/platforms 一律留空），
# 避免 auto 默认把 llvmpipe/x11/wayland 等拖进来、引入一堆无关 host 依赖。
meson setup "$NATIVE_BUILD" "$MESA_SRC" \
  --native-file="$NATIVE_INI" \
  --prefix="$NATIVE_TOOLS" \
  --buildtype=release \
  -Dmesa-clc=enabled \
  -Dinstall-mesa-clc=true \
  -Dprecomp-compiler=enabled \
  -Dinstall-precomp-compiler=true \
  -Dtools=panfrost \
  -Dllvm=enabled \
  -Dshared-llvm=enabled \
  -Dcpp_rtti="$RTTI" \
  -Dgallium-drivers= \
  -Dvulkan-drivers= \
  -Dplatforms= \
  -Dglx=disabled \
  -Dmicrosoft-clc=disabled \
  -Dexpat=disabled \
  -Dxmlconfig=disabled \
  -Dzstd=disabled \
  -Dbuild-tests=false

log "编译原生 CLC 工具（ninja）"
ninja -C "$NATIVE_BUILD"

log "安装到 $NATIVE_TOOLS/bin"
ninja -C "$NATIVE_BUILD" install

# ---- 校验三个工具就位 + host 可执行（x86_64，动态库齐全）----
for t in mesa_clc vtn_bindgen2 panfrost_compile; do
  [ -x "$NATIVE_TOOLS_BIN/$t" ] || die "原生工具未产出：$NATIVE_TOOLS_BIN/$t（检查上面 meson/ninja 日志）"
done
log "原生 CLC 工具就绪："
ls -l "$NATIVE_TOOLS_BIN"/mesa_clc "$NATIVE_TOOLS_BIN"/vtn_bindgen2 "$NATIVE_TOOLS_BIN"/panfrost_compile >&2

# 冒烟：mesa_clc 能在 host 跑起来（证明不是 arm64、且 libLLVM/libclang-cpp 都能加载）
if command -v readelf >/dev/null 2>&1; then
  m="$(readelf -h "$NATIVE_TOOLS_BIN/mesa_clc" 2>/dev/null | awk -F: '/Machine/{gsub(/^ +/,"",$2);print $2}')"
  log "  mesa_clc Machine = ${m:-?}（应为 host x86-64，非 AArch64）"
fi
"$NATIVE_TOOLS_BIN/mesa_clc" --help >/dev/null 2>&1 \
  && log "  mesa_clc --help OK" \
  || warn "  mesa_clc --help 返回非零（多半正常，继续）"

log "下一步：20-build-mesa.sh 会把 $NATIVE_TOOLS_BIN 前置到 PATH，并用"
log "       -Dmesa-clc=system -Dprecomp-compiler=system 复用这些工具做交叉构建。"
