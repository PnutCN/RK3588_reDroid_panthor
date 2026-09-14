# device_redroid-prebuilts 布局对照与合并说明

本脚手架 `30-package-prebuilts.sh` 产出的目录，严格对齐
[`remote-android/device_redroid-prebuilts`](https://github.com/remote-android/device_redroid-prebuilts)
（本分析树克隆 @ `6248d6a`）的 `Android.mk` 期望布局，便于直接替换其 arm64 预编译库。

## 1. 目录布局（prebuilts/arm64/）

```text
prebuilts/arm64/
├── lib/
│   ├── egl/
│   │   ├── libEGL_mesa.so            <- Mesa: -Degl-lib-suffix=_mesa
│   │   ├── libGLESv1_CM_mesa.so      <- Mesa: -Dgles-lib-suffix=_mesa -Dgles1=enabled
│   │   └── libGLESv2_mesa.so         <- Mesa: -Dgles-lib-suffix=_mesa -Dgles2=enabled
│   ├── dri/
│   │   ├── libgallium_dri.so         <- Mesa gallium megadriver（含 panfrost + panthor KMD）
│   │   ├── panfrost_dri.so  -> libgallium_dri.so   (软链)
│   │   └── kmsro_dri.so     -> libgallium_dri.so   (软链，若 mesa 生成)
│   ├── hw/
│   │   └── libvulkan_panfrost.so     <- PanVK（-Dvulkan-drivers=panfrost）
│   ├── libgbm.so.1 (.0.0)            <- Mesa: -Dgbm=enabled
│   ├── libglapi.so.0 (.0.0)          <- Mesa 共享 glapi
│   ├── libdrm.so.2 (.x.y)            <- 10-build-libdrm.sh 交叉构建
│   └── libc++_shared.so              <- NDK 提供
└── share/vulkan/icd.d/
    └── panfrost_icd.*.json           <- 可选（Android 主要靠 ro.hardware.vulkan=panfrost）
```

## 2. 与上游 Android.mk 的模块映射

`device_redroid-prebuilts/Android.mk` 用 `define-redroid-prebuilt-lib` 把上面的文件
声明为 AOSP 预编译模块。关键映射（核对自该仓库 `Android.mk` / `prebuilts*.mk`）：

| 上游模块名 | 源文件（prebuilts/arm64/…） | 安装位置 | 由谁产生 |
| --- | --- | --- | --- |
| `libEGL_mesa` / `libGLESv1_CM_mesa` / `libGLESv2_mesa` | `lib/egl/*.so` | `/vendor/lib64/egl/` | **本脚手架(Mesa)** |
| `libgallium_dri` (+ `*_dri.so` 软链) | `lib/dri/libgallium_dri.so` | `/vendor/lib64/dri/` | **本脚手架(Mesa)** |
| `vulkan.panfrost` | `lib/hw/libvulkan_panfrost.so` | `/vendor/lib64/hw/` | **本脚手架(PanVK)** |
| `libgbm.so.1` / `libglapi.so.0` / `libdrm*.so.*` | `lib/*.so.*` | `/vendor/lib64/` | **本脚手架(Mesa/libdrm)** |
| `libc++_shared_p` | `lib/libc++_shared.so` | `/vendor/lib64/` | NDK |
| `gralloc.gbm` | `lib/hw/gralloc.gbm.so` | `/vendor/lib64/hw/` | **reDroid 上游，非 Mesa** |
| `gralloc.cros` | `lib/hw/gralloc.cros.so` | `/vendor/lib64/hw/` | reDroid 上游，非 Mesa |
| `hwcomposer.redroid` | `lib/hw/hwcomposer.redroid.so` | `/vendor/lib64/hw/` | **reDroid 上游，非 Mesa** |
| `audio.primary.redroid` / `uinputd` / `vncserver` / VA 系列 | `lib/hw`,`bin` | `/vendor/...` | reDroid 上游，非 Mesa |

> `prebuilts_arm.mk` 里 `PRODUCT_PACKAGES += vulkan.panfrost` —— 这正是本脚手架
> PanVK 产物对应的模块名。清单 6.4 提到 `ro.hardware.vulkan=panfrost` 也指向它。

## 3. 合并策略（重要）

本脚手架**只替换 Mesa/libdrm 派生的那部分 .so**，绝不触碰 reDroid 自身的
`gralloc.gbm.so` / `hwcomposer.redroid.so` / `audio.primary.redroid.so` /
`uinputd` / `vncserver` / VA-API 系列（对应清单 6.3：gralloc/HWC 走 reDroid 上游）。

合并到一个已 checkout 的 `device_redroid-prebuilts` 工作树：

```bash
# 方式 A：让打包脚本直接写进上游树（推荐）
PREBUILTS_DST=/path/to/device_redroid-prebuilts/prebuilts/arm64 \
  scripts/30-package-prebuilts.sh
# 只覆盖 egl/ dri/ hw/libvulkan_panfrost.so libgbm/libglapi/libdrm/libc++_shared，
# gralloc.gbm.so / hwcomposer.redroid.so 等保持上游原样（脚本不生成、不删除它们）。

# 方式 B：先产出到独立目录，再人工 rsync 合并
scripts/30-package-prebuilts.sh           # -> $WORK/out/prebuilts/arm64
rsync -av --exclude 'gralloc.*' --exclude 'hwcomposer.*' --exclude 'audio.*' \
  "$WORK/out/prebuilts/arm64/" /path/to/device_redroid-prebuilts/prebuilts/arm64/
```

合并后按 upstream 流程（清单 6.1）在 LineageOS 20 树里编 reDroid 镜像即可。
`Android.mk` 无需改动：它用 `find * -name '*_dri.so' -type l` 动态发现驱动软链，
用 `find * -name 'libvulkan_*.so'` 动态发现 Vulkan HAL，天然适配本脚手架产物。

## 4. 为什么不能直接用宿主 Ubuntu 的 Mesa .deb（清单 6.2 line269）

| 维度 | 宿主 Ubuntu Mesa(.deb) | 本脚手架产物 |
| --- | --- | --- |
| libc / 动态链接器 | glibc + `ld-linux-aarch64.so` | Bionic + `/system/bin/linker64` |
| 依赖 SONAME | `libpthread.so.0`/`libdl.so.2`/`libm.so.6`… | `libc.so`/`liblog.so`/`libsync.so`/`libnativewindow.so`… |
| EGL/GLES 命名 | `libEGL.so.1`（glvnd） | `libEGL_mesa.so`（Android 加载器按 `ro.hardware.egl` dlopen） |
| HAL ABI | 无 Android HAL | `vulkan.panfrost` HAL、gralloc 互操作 |
| Panthor KMD | 视发行版 mesa 版本，未必含 | **本脚手架强制含**（40-verify-panthor.sh 校验） |

`40-verify-panthor.sh` 的 DT_NEEDED 检查会**主动拒绝**出现 glibc 专有 SONAME，
确保不会误把宿主库打进容器。
