# Android Mesa + PanVK + GBM 构建脚手架（reDroid / RK3588 Panthor）

本目录是移植清单
[`OrangePi5Max_..._reDroid_移植清单.md`](../../OrangePi5Max_ubuntu-rockchip-optimized_Panthor_reDroid_移植清单.md)
中 **6.1 / 6.2 / 6.3** 的“可在代码层落地”的构建脚手架：用 **NDK + meson 交叉编译**，
为 Android arm64（Bionic）重建一套含 **Panthor KMD** 的 Mesa（Panfrost gallium + PanVK
+ GBM + EGL/GLES），并落位成 `device_redroid-prebuilts` 的预编译布局。

> 命名提醒（清单第 5 节）：**内核驱动叫 `panthor`，Mesa gallium 驱动仍叫 `panfrost`，
> Vulkan HAL 文件仍叫 `libvulkan_panfrost.so`，Android 属性仍是 `ro.hardware.vulkan=panfrost`。**
> 本脚手架构建的 `libgallium_dri.so` / `libvulkan_panfrost.so` 内部同时注册 panfrost 与
> **panthor** 两个 KMD 后端，运行时按内核驱动名（`panthor`）自动分派到 `DRM_IOCTL_PANTHOR_*`。

---

## 1. 为什么是“NDK 交叉编译”，而不是别的

| 路线 | 结论 |
| --- | --- |
| 复制宿主 Ubuntu 的 Mesa `.deb` 进容器 | ❌ 清单 6.2 line269 明令禁止：glibc/动态链接器/HAL ABI 全不同 |
| 在 x86_64 上用 qemu 模拟 arm64 原生编译 | ❌ 慢数倍、易崩（清单 14 已验证宿主镜像走原生 arm runner 更优） |
| **NDK + meson 交叉编译（x86_64 → aarch64-linux-android）** | ✅ 本脚手架采用：真交叉、无需 arm 机器/模拟，普通 x86_64 CI 即可，快 |
| 完整 LineageOS 20 树内 Soong 构建（Waydroid/reDroid 方式） | ✅ 生产终局；本脚手架的 cross-file/选项集可直接移植进 `external/mesa3d`（见 §7） |

参考实现：`remote-android/mesa` 的
`.gitlab-ci/container/{create-android-cross-file.sh, create-android-ndk-pc.sh, debian/android_build.sh}`
与 `android/mesa3d_cross.mk`（本分析树 `mesa-meta/` 克隆 @ `50802f9`）。本脚手架把其
NDK r21d + `<arch>29-clang` 旧写法升级为现代 NDK（r27c）统一 `clang --target=` 写法，
并对齐 Mesa 26.3 的选项名。

---

## 2. 目录结构

```text
android-mesa/
├── VERSIONS.env                     # 冻结版本/可调参数（Mesa commit、libdrm、NDK、API、AOSP tag）
├── cross/
│   └── android-aarch64.ini.in       # meson cross-file 模板（NDK LLVM 工具链）
├── scripts/
│   ├── common.sh                    # 公共前置：路径/NDK 解析/.pc 与 stub 生成/AOSP 头拉取
│   ├── 00-fetch-sources.sh          # 备齐 NDK + Mesa 全量树 + libdrm 源码
│   ├── gen-android-sysroot.sh       # 渲染 cross-file + 生成 pkg-config 垫片 + AOSP 头/stub
│   ├── 10-build-libdrm.sh           # 交叉构建 libdrm，装入垫片 sysroot
│   ├── 20-build-mesa.sh             # 交叉构建 Mesa（panfrost+panvk+gbm+egl/gles, android）
│   ├── 30-package-prebuilts.sh      # 落位成 device_redroid-prebuilts/prebuilts/arm64 布局
│   ├── 40-verify-panthor.sh         # readelf/strings 校验（清单 6.2 line270）
│   └── build-all.sh                 # 一键流水线
├── packaging/
│   └── PREBUILTS-LAYOUT.md          # 与上游 Android.mk 的模块映射 + 合并策略
├── .github/
│   └── workflows/
│       └── android-mesa.yml         # GitHub Actions（x86_64 runner + 预装 NDK，产物发 Release）
└── README.md                        # 本文件
```

---

## 3. 前置依赖

构建机（x86_64 Linux 或 GH Actions `ubuntu-latest`）需要：

- `meson`（>= 1.4，Mesa 26.3 要求）、`ninja`、`pkg-config`
- `python3` + **`python3-mako`**（Mesa 代码生成：pan_packers / vulkan entrypoints）
- `git`、`curl`、`unzip`、`xz-utils`、`ccache`（可选，加速）
- **Android NDK**：优先用环境已有的 `$ANDROID_NDK_LATEST_HOME` / `$ANDROID_NDK_HOME`
  （GH runner 预装）；否则 `00-fetch-sources.sh` 按 `VERSIONS.env:NDK_VERSION` 下载 r27c
- 网络：拉 Mesa（gitlab.freedesktop.org）、libdrm（dri.freedesktop.org）、
  AOSP 头（github.com/LineageOS，仅 `full` 路线需要）

```bash
sudo apt-get install -y meson ninja-build pkg-config python3-mako ccache unzip xz-utils git curl
```

---

## 4. 快速开始

```bash
cd opi5max-panthor/android-mesa

# 生产路线：完整 android platform（拉 AOSP 头垫片 + 造 libcutils/libhardware stub）
./scripts/build-all.sh

# 工具链冒烟：不拉 AOSP 头，用 -Dandroid-stub=true 快速验证 NDK+meson+选项集能编过
#（产物不可上板，仅证明交叉工具链与 Mesa 配置成立）
ANDROID_STUB=1 ./scripts/build-all.sh

# 指定大容量工作目录 / 加软件回退驱动
WORK=/big/disk GALLIUM_DRIVERS=panfrost,softpipe ./scripts/build-all.sh
```

产物默认在 `.work/out/prebuilts/arm64/`。分步跑：

```bash
./scripts/00-fetch-sources.sh        # NDK + Mesa 全量树 + libdrm 源码
./scripts/gen-android-sysroot.sh     # cross-file + .pc 垫片 + AOSP 头/stub
./scripts/10-build-libdrm.sh         # libdrm -> 垫片 sysroot
./scripts/20-build-mesa.sh           # Mesa -> .work/stage/vendor/lib64
./scripts/30-package-prebuilts.sh    # -> .work/out/prebuilts/arm64
./scripts/40-verify-panthor.sh       # 校验含 panthor KMD / arm64 ABI / 依赖洁净
```

---

## 5. Mesa 选项集与依据（均在 `mesa-current` 源码核对）

`20-build-mesa.sh` 的核心选项（Mesa `25b4dfa` / 26.3.0-devel）：

| 选项 | 值 | 依据 |
| --- | --- | --- |
| `-Dplatforms` | `android` | meson.build:512 —— android 只能单独启用 |
| `-Dplatform-sdk-version` | `33` | LineageOS 20 = Android 13；meson.build:625 对 >=29 启用 ELF-TLS 修正 |
| `-Dgallium-drivers` | `panfrost` | 26.x 已无独立 `kmsro` 选项（随 panfrost 内建）；meson.options:83 choices |
| `-Dvulkan-drivers` | `panfrost` | **PanVK** 源码在 `src/panfrost/vulkan`，产物 `libvulkan_panfrost.so`；meson.options:206 |
| `-Dgbm` | `enabled` | reDroid `gralloc.gbm` 需要 libgbm；android ∈ `system_has_kms_drm`(meson.build:161) |
| `-Degl`/`-Dgles1`/`-Dgles2` | `enabled` | 产出 `libEGL_mesa`/`libGLESv1_CM_mesa`/`libGLESv2_mesa` |
| `-Degl-lib-suffix`/`-Dgles-lib-suffix` | `_mesa` | Android 加载器按 `ro.hardware.egl=mesa` dlopen `libEGL_mesa.so` |
| `-Dglvnd` | `disabled` | meson.build:696 —— 用 lib suffix 时必须关 glvnd |
| `-Dllvm` | `disabled` | panfrost/panvk 不需要 LLVM，避免巨型依赖 |
| `-Dexpat`/`-Dxmlconfig` | `disabled` | meson.build:1934 —— Android 上 xmlconfig 不可用 |
| `-Dandroid-libbacktrace`/`-Dandroid-libperfetto`/`-Dperfetto`/`-Dlibunwind` | `disabled`/`false` | 去掉 backtrace/perfetto/libunwind 依赖（meson.build:2247 Android 不用 libunwind） |
| `-Dandroid-strict` | `true` | CTS 合规（生产默认） |
| `-Dcpp_rtti` | `false` | 对齐上游 android cross.mk；配合 cross-file 的 `-fno-exceptions` |
| `-Ddri-drivers-path` | `/vendor/lib64/dri` | 编译进产物的运行时 DRI 搜索路径 |

**依赖来源**（`gen-android-sysroot.sh` 生成的 `.pc` 垫片，对应上游 `MESON_GEN_PKGCONFIGS`）：

- NDK 原生：`zlib` `log` `sync` `nativewindow`（NDK sysroot 有库，clang `--target` 自动搜）
- 交叉构建：`libdrm`（`10-build-libdrm.sh` 装入垫片，自带 `libdrm.pc`）
- AOSP 专有头（NDK 缺，从 pin 的 LineageOS `lineage-20.0` 稀疏拉取）：
  `cutils/` `hardware/` `log/` `sync/` `nativewindow/` `system/` `hwvulkan/`
- 链接期 stub `.so`：`libcutils.so` `libhardware.so`（NDK 无；运行时用设备真实库解析同名 SONAME）
- 不需要：`expat`（Android 关 xmlconfig）、`libelf`（meson `required:false`→null_dep）

---

## 6. 校验（清单 6.2 line270）

`40-verify-panthor.sh` 用 `readelf`/`strings` 落实“**确认含 panthor KMD，而非仅旧
panfrost_kmod**”，判据全部源自 `mesa-current` 源码：

1. **Panthor 字符串**：`pan_kmod.c` 分派表同时含 `"panfrost"`(line23) 与 `"panthor"`(line27)
   并对内核驱动名 `strcmp`；产物 `.rodata` 必出现**独立** `panthor` 字符串。若只有
   `panfrost` 而无 `panthor` → 判 FAIL（正是清单警告的旧 KMD 情形）。
2. **panthor_kmod 实现串**：`panthor_kmod.c` 的错误串（`panthor_kmod ...`）。
3. **符号表**（未 strip 时）：`panthor_kmod_ops` / `panthor_kmod_dev_create`。
4. **ELF ABI**：ELF64 / Machine=AArch64 / Type=DYN（拒绝宿主 x86-64 泄漏）。
5. **DT_NEEDED 洁净**：必须含 `libdrm.so*`（panthor ioctl 经 `drmIoctl`）；
   **拒绝** `libLLVM*`（我们 `-Dllvm=disabled`）与 glibc 专有 SONAME
   （`libpthread.so.0`/`libdl.so.2`/`libm.so.6`/`ld-linux*`）。
6. **GBM 导出符号**：`gbm_create_device`/`gbm_bo_create`/`gbm_bo_get_fd`（gralloc.gbm 需要）。

退出码 0=全 PASS，1=有 FAIL（CI 据此门禁）。

---

## 7. CI（`.github/workflows/android-mesa.yml`）

- 跑在 **`ubuntu-latest`（x86_64）**：NDK 交叉编译，**无需 arm runner、无 qemu**。
- 用 runner **预装 NDK**（`$ANDROID_NDK_LATEST_HOME`），省去下载。
- `workflow_dispatch` 可选 `route=full|smoke`、自定义 gallium/vulkan 驱动。
- 每次运行都发 **public Release**：`android-mesa-panthor-prebuilts.tar.gz`（成功时）
  + `verify-panthor.txt` + `build.log`（失败也在），与 `opi5max.yml` 一致的免认证取回策略。

本仓库即独立脚手架仓库，workflow 已在生效位置 `.github/workflows/android-mesa.yml`，`env.SCAFFOLD_DIR=.`（脚手架在仓库根）；push 到 `main` 或到 Actions 手动 Run workflow 即触发。

---

## 8. 与 in-tree AOSP 路线的关系（生产终局）

本脚手架的 **cross-file + 选项集 + 依赖分析** 可直接移植进 LineageOS 20 树的
`external/mesa3d`（Waydroid/reDroid 的 `BOARD_MESA3D_USES_MESON_BUILD` 方式，参考
`mesa-meta/android/mesa3d_cross.mk`）：把 §5 的选项写进 `MESON_GEN_NINJA`，把
`BOARD_MESA3D_GALLIUM_DRIVERS := panfrost`、`BOARD_MESA3D_VULKAN_DRIVERS := panfrost`
写进 `BoardConfig.mk` 即可。in-tree 路线的好处是 AOSP 头/libcutils/libhardware 原生可用，
无需本脚手架的 stub 垫片； standalone 路线的好处是**不需要 100GB 的 AOSP 树**、可在
普通 CI 上快速迭代与校验 Panthor 是否编进产物。

---

## 9. 已知限制 / 待实机验证（对应 Gate 1 / Gate 2）

本脚手架完成的是 **“把含 Panthor 的 Android Mesa 编出来并校验”**（清单 6.2 的代码层）。
以下仍需在真实 reDroid 容器 + RK3588 Panthor 宿主上验证，**本分析环境无法执行**：

- **Gate 1（EGL/gralloc）**：`gralloc.gbm` 能否从 Panthor render node 创建 GBM BO，
  并以 dma-buf + fence 在 SurfaceFlinger/HWC 间传递（清单 6.3、7 Gate 1）。
- **Gate 2（Vulkan/PanVK）**：`libvulkan_panfrost.so` 在容器内经 Panthor 跑通 Vulkan
  （清单 7 Gate 2）。建议先 GLES 后 Vulkan，不要同时调试（清单 9 第 6 条）。
- **运行时属性/SELinux/权限**：`ro.hardware.egl=mesa`、`ro.hardware.gralloc=gbm`、
  `ro.hardware.vulkan=panfrost`、render node 的 `render` GID、seccomp/DRM ioctl 放行
  （清单 6.4/6.5，已在 `vendor_redroid/gpu_config.sh` 侧补 `panthor` 检测）。
- **AOSP 头 tag 漂移**：`VERSIONS.env:AOSP_TAG=lineage-20.0` 若上游移动，
  `gen-android-sysroot.sh` 的关键头存在性校验会 `die` 提示核对。

> 冒烟路线（`ANDROID_STUB=1`）只证明工具链/选项集成立，其 `-Dandroid-stub=true`
> 产物**缺少真实 gralloc/nativewindow 互操作，不可上板**。
