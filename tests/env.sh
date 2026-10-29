# Environment of the run: CPU, hypervisor, kernel, disk.

cpu_flag() { grep -qw "$1" /proc/cpuinfo && echo true || echo false; }

# Prints true for a rotational disk, false for SSD, null if unknown. Partitions are checked via their parent disk.
rotational() { # /dev/name
    local dev=/sys/class/block/${1##*/}
    [[ -e $dev ]] || { echo null; return; }
    [[ -e $dev/partition ]] && dev=$(readlink -f "$dev")/..
    case $(cat "$dev/queue/rotational" 2>/dev/null) in 1) echo true ;; 0) echo false ;; *) echo null ;; esac
}

collect_env() {
    local model virt vendor product source fstype
    model=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)
    [[ -z $model ]] && model=$(lscpu | awk -F': +' '/^Model name/{print $2; exit}')
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
    product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    virt=$(lscpu | awk -F': +' '/^Hypervisor vendor/{print $2}')
    read -r source fstype < <(findmnt -no SOURCE,FSTYPE --target "$WORK" | head -1)
    source=${source%%\[*}

    jq -n --arg model "$model" --argjson nproc "$NPROC" \
        --arg mhz "$(lscpu | awk -F': +' '/^CPU max MHz/{print $2}')" \
        --argjson aes "$(cpu_flag aes)" --argjson avx2 "$(cpu_flag avx2)" --argjson avx512 "$(cpu_flag avx512f)" \
        --argjson sha "$(cpu_flag sha_ni)" \
        --argjson mem "$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)" \
        --argjson swap "$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)" \
        --arg virt "$virt" --arg vendor "$vendor" --arg product "$product" \
        --arg docker "$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)" \
        --arg kernel "$(uname -r)" --arg arch "$(uname -m)" --arg os "$HOST_OS" \
        --arg device "$source" --arg fstype "$fstype" --argjson rotational "$(rotational "$source")" \
        --argjson disk_free "$(df -BG --output=avail "$WORK" | tail -1 | tr -dc 0-9)" \
        '{cpu: {model: $model, vcpu: $nproc, max_mhz: (if $mhz == "" then null else ($mhz | tonumber) end),
            flags: {aes: $aes, avx2: $avx2, avx512f: $avx512, sha_ni: $sha}},
          memory_mb: $mem, swap_mb: $swap,
          virtualization: {hypervisor: (if $virt == "" then null else $virt end), sys_vendor: $vendor, product: $product},
          kernel: $kernel, arch: $arch, host_os: $os, docker: (if $docker == "" then null else $docker end),
          disk: {device: $device, fs: $fstype, rotational: $rotational, free_gb: $disk_free}}'
}
