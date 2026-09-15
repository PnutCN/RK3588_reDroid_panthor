# redroid-rk3588-panthor 镜像构建

产出「可用的 reDroid 镜像」：**上游 reDroid arm64 镜像** + **交叉构建的 Panthor 版
Mesa/PanVK/GBM**（本仓库 `android-mesa` workflow 的 Release 产物）**drop-in 替换**。

目标硬件：Orange Pi 5 Max / RK3588 / Mali-G610（内核 Panthor KMD）。
宿主须已烧主线 Panthor 内核镜像并通过 Gate 0（`/dev/dri/renderD128` 由 panthor 驱动）。

## 为什么是 drop-in 替换，而不是全量自建

- 全量 AOSP/LineageOS 构建需 ~400GB、数小时，超出 GitHub Actions runner 限额。
- 上游 reDroid 镜像已含完整 Android rootfs + `gralloc.gbm.so` / `hwcomposer.redroid.so` /
  `audio.primary.redroid.so` / `uinputd` / `vncserver`。
- 我们只需替换其中的 **Mesa/libdrm/GBM 派生库** + **panthor 版 `gpu_config.sh`**，
  其余保持上游原样（移植清单 6.3：gralloc/HWC 走上游不重建）。

## 渲染栈

```
Android App / SurfaceFlinger
  -> EGL / GLES / Vulkan            (ro.hardware.egl=mesa, ro.hardware.vulkan=panfrost)
  -> Android arm64 Mesa (Bionic)     libEGL_mesa / libgallium_dri / vulkan.panfrost
  -> GBM gralloc + dma-buf           libgbm.so.1  (上游 gralloc.gbm.so DT_NEED)
  -> /dev/dri/renderD128
  -> 内核 Panthor KMD -> RK3588 Mali-G610
```

命名要点：内核驱动叫 **panthor**，Mesa Gallium driver 仍叫 **panfrost**，
Vulkan HAL 文件叫 **vulkan.panfrost.so**，prop `ro.hardware.vulkan=panfrost`。

## 命名对齐（核心难点）

Mesa 25.x 交叉构建（platform-sdk-version>=30）产出的库名与上游 reDroid 镜像期望的名字
不完全一致。`inject-mesa.sh` 依据实测 SONAME + `device_redroid-prebuilts/Android.mk` +
Bionic 链接器行为，做如下对齐：

| 源（run #N 产物）                | 注入到镜像                     | 手法 / 依据 |
|----------------------------------|--------------------------------|-------------|
| `lib/egl/libEGL_mesa.so*` 等     | `/vendor/lib64/egl/`（原样）   | `ro.hardware.egl=mesa` |
| `lib/dri/libgallium_dri.so`+软链 | `/vendor/lib64/dri/`（原样）   | 含 panfrost + panthor KMD |
| `lib/hw/libvulkan_panfrost.so`   | `/vendor/lib64/hw/vulkan.panfrost.so` | **改名**：Android Vulkan loader 按路径 `dlopen(/vendor/lib64/hw/vulkan.<ro.hardware.vulkan>.so)`，SONAME 不参与 |
| `lib/libgbm_mesa.so.1.0.0`（SONAME=`libgbm_mesa.so.1`） | `/vendor/lib64/libgbm.so.1.0.0`（SONAME→`libgbm.so.1`）+ 软链 `libgbm.so.1`/`libgbm.so` | **patchelf 改 SONAME**：上游 `gralloc.gbm.so` DT_NEED `libgbm.so.1`；本 Mesa 栈内无任何库 DT_NEED libgbm，故 libgbm 是纯叶子，改名安全 |
| `lib/libdrm.so`（SONAME=`libdrm.so`） | `/vendor/lib64/libdrm.so` + 别名软链 `libdrm.so.2` | Bionic 按 realpath 去重，两名解析到同一 soinfo，单实例无双份全局态 |
| `lib/libc++_shared.so`           | `/vendor/lib64/libc++_shared.so`（原样） | NDK 运行时 |
| panthor 版 `gpu_config.sh`       | `/vendor/bin/gpu_config.sh`(0755) | 覆盖上游只认 panfrost 的版本 |

**绝不触碰** reDroid 自身的 `gralloc.gbm.so` / `hwcomposer.redroid.so` /
`audio.primary.redroid.so` / `uinputd` / `vncserver`。

## 文件

- `inject-mesa.sh <prebuilts_arm64_dir> <overlay_out_dir> [gpu_config.sh]`
  把 Mesa 产物排布成 `/vendor` overlay（命名对齐见上）。
- `verify-image.sh <exported_vendor_dir>`
  校验注入后镜像的 `/vendor`（7 项：文件存在 / arm64 ABI / Panthor KMD 证据 /
  SONAME 对齐 / gpu_config panthor / **上游保留二进制的 Mesa 依赖闭合** / LLVM-free）。
- `build-image.sh`  编排器：解析 Mesa 产物 → `docker pull` base → 探测 base `/vendor`
  布局 → `inject-mesa.sh` → `docker build` → 导出 `/vendor` 校验 → `docker save`。
- `Dockerfile.tmpl`  `FROM @BASE_IMAGE@` + `COPY overlay/ /`。
- `gpu_config.sh`  panthor 检测版（来自 `vendor_redroid`）。

### build-image.sh 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `MESA_SRC` | （必填） | Mesa 产物：`.tar.gz` / 含 `prebuilts/arm64` 的目录 / Release 直链 URL |
| `BASE_IMAGE` | `redroid/redroid:13.0.0-latest` | 基座镜像（arm64） |
| `OUT_IMAGE` | `redroid-rk3588-panthor:lineage-20` | 产出镜像 tag |
| `WORK` | `./.work-image` | 工作目录 |
| `GPU_CONFIG` | 同目录 `gpu_config.sh` | panthor 版脚本 |
| `SAVE_IMAGE` | `1` | 是否 `docker save` 成压缩包 |
| `REMOVE_LLVM` | `0` | 是否移除孤儿 `libLLVM*`（默认不移除：Android rootfs 可能缺 `/bin/sh`，Dockerfile 保持 COPY-only 更安全；我们的栈 LLVM-free，孤儿库无害） |

## 本地构建

```bash
MESA_SRC=/path/to/android-mesa-panthor-prebuilts.tar.gz \
BASE_IMAGE=redroid/redroid:13.0.0-latest \
OUT_IMAGE=redroid-rk3588-panthor:lineage-20 \
  bash redroid-image/build-image.sh
```

需在 **arm64 主机**（或有 arm64 docker + qemu）上运行：拉/建/导出 arm64 镜像、
`readelf` arm64 库、Dockerfile 原生执行。

## CI

`.github/workflows/redroid-image.yml`（`runs-on: ubuntu-24.04-arm`，原生 arm64 docker）：
Checkout → 装工具（patchelf/binutils/zstd/jq）→ 解析最新 Mesa Release → `build-image.sh`
→ 推 GHCR（`ghcr.io/<owner>/redroid-rk3588-panthor:<tag>` + `latest`）→ 发布 Release
（`docker save` 包 + `verify-image.txt` + `build.log`）。

触发：push 到 `main` 且改动 `redroid-image/**` 或本 workflow；或 Actions 页手动 Run workflow。

## 在板上运行

宿主已烧主线 Panthor 镜像、Gate 0 通过后：

```bash
# 方式 A：从 GHCR
docker run -itd --privileged --device /dev/dri/renderD128 \
  -v ~/redroid-data:/data -p 5555:5555 \
  ghcr.io/<owner>/redroid-rk3588-panthor:lineage-20 \
  androidboot.redroid_gpu_mode=host \
  androidboot.redroid_gpu_node=/dev/dri/renderD128

# 方式 B：从 Release 的 tar 包
zstd -dc redroid-rk3588-panthor.tar.zst | docker load
# 然后同上 docker run
```

连接：`adb connect <host-ip>:5555`。

## 已知边界

CI **无法** runtime 启动 reDroid（需 binder/内核模块，GH runner 不支持）。这里的「可用」
依赖：正确的库 + 路径 + 命名 + props + panthor 检测，匹配已验证的上游架构。真正的
Gate 1/2 运行时验收须在烧了主线宿主镜像（Gate 0 通过）的 Orange Pi 5 Max 板上做。
