#!/system/bin/sh

# args: driver
setup_vulkan() {
    echo "setup vulkan for driver: $1"
    case "$1" in
        i915)
            setprop ro.hardware.vulkan intel
            ;;
        amdgpu)
            setprop ro.hardware.vulkan radeon
            ;;
        virtio_gpu)
            setprop ro.hardware.vulkan virtio
            ;;
        v3d|vc4)
            setprop ro.hardware.vulkan broadcom
            ;;
        msm_drm)
            setprop ro.hardware.vulkan freedreno
            ;;
        # The CSF kernel driver is "panthor" and the JM kernel driver is
        # "panfrost", but both are served by the same Mesa Panfrost Vulkan HAL
        # (libvulkan_panfrost.so), so ro.hardware.vulkan stays "panfrost".
        panfrost|panthor)
            setprop ro.hardware.vulkan panfrost
            ;;
        *)
            echo "not supported driver: $1"
            ;;
    esac
}

# Whitelist of DRM kernel drivers we know how to drive through Mesa/GBM.
is_supported_driver() {
    case "$1" in
        i915|amdgpu|nouveau|virtio_gpu|v3d|vc4|msm_drm|panfrost|panthor)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Resolve the DRM driver name backing a render node minor (e.g. 128 for
# /dev/dri/renderD128). The upstream code only read debugfs, which a container
# frequently does not have mounted, so prefer sysfs and treat debugfs as an
# optional extra source.
detect_driver() {
    minor="$1"
    driver=""

    # 1) sysfs driver symlink: /sys/class/drm/renderD<minor>/device/driver
    drv_link="/sys/class/drm/renderD${minor}/device/driver"
    if [ -e "$drv_link" ]; then
        driver=$(basename "$(readlink -f "$drv_link")")
    fi

    # 2) debugfs fallback (only when the container has it mounted)
    if [ -z "$driver" ]; then
        name_file="/sys/kernel/debug/dri/${minor}/name"
        if [ -r "$name_file" ]; then
            driver=$(cut -d' ' -f1 "$name_file")
        fi
    fi

    echo "$driver"
}

setup_render_node() {
    node=$(getprop ro.boot.redroid_gpu_node)
    if [ -n "$node" ]; then
        echo "force render node: $node"

        if [ ! -e "$node" ]; then
            echo "ERROR: forced render node $node does not exist"
            return 1
        fi

        minor="${node#/dev/dri/renderD}"
        driver=$(detect_driver "$minor")
        echo "forced node driver: ${driver:-unknown}"

        if ! is_supported_driver "$driver"; then
            echo "ERROR: forced node $driver is not a supported GPU driver"
            return 1
        fi

        setprop gralloc.gbm.device "$node"
        chmod 666 "$node"

        # setup vulkan
        setup_vulkan "$driver"
        return 0
    fi

    # Enumerate render nodes through sysfs so this works without debugfs.
    for path in /sys/class/drm/renderD* ; do
        [ -e "$path" ] || continue
        card=$(basename "$path")        # e.g. renderD128
        minor="${card#renderD}"         # e.g. 128
        driver=$(detect_driver "$minor")
        echo "DRI node exists, driver: ${driver:-unknown}"
        if is_supported_driver "$driver"; then
            node="/dev/dri/renderD${minor}"
            echo "use render node: $node"
            setprop gralloc.gbm.device "$node"
            chmod 666 "$node"
            setup_vulkan "$driver"
            return 0
        fi
    done

    echo "NO qualified render node found"
    return 1
}


gpu_setup_host() {
    echo "use GPU host mode"

    setprop ro.hardware.egl mesa
    setprop ro.hardware.gralloc gbm
    setprop ro.boot.redroid_fps 30
}

gpu_setup_guest() {
    echo "use GPU guest mode"

    VENDOR_EGL_DIR=/vendor/lib64/egl
    SYSTEM_EGL_DIR=/system/lib64
    EGL_ANGLE=libEGL_angle.so
    EGL_SS=libEGL_swiftshader.so
    egl=

    if [ -f $VENDOR_EGL_DIR/$EGL_ANGLE ] || [ -f $SYSTEM_EGL_DIR/$EGL_ANGLE ]; then
        egl=angle
    elif [ -f $VENDOR_EGL_DIR/$EGL_SS ] || [ -f $SYSTEM_EGL_DIR/$EGL_SS ]; then
        egl=swiftshader
    else
        echo "ERROR no SW egl found!!!"
    fi

    setprop ro.hardware.egl $egl
    setprop ro.hardware.gralloc redroid
    setprop ro.hardware.vulkan pastel
}

gpu_setup() {
    ## mode=(auto, host, guest)
    ## node=(/dev/dri/renderDxxx)

    mode=$(getprop ro.boot.redroid_gpu_mode guest)
    if [ "$mode" = "host" ]; then
        if setup_render_node; then
            gpu_setup_host
        else
            echo "ERROR: host GPU mode requested but no usable render node;"
            echo "       falling back to guest software rendering (no fake GPU accel)."
            gpu_setup_guest
        fi
    elif [ "$mode" = "guest" ]; then
        gpu_setup_guest
    elif [ "$mode" = "auto" ]; then
         echo "use GPU auto mode"
         if setup_render_node; then
            gpu_setup_host
         else
            gpu_setup_guest
         fi
    else
        echo "unknown mode: $mode"
    fi
}

gpu_setup

