# Disk tests with fio and direct I/O, on a file in $WORK (a bind mount on the root filesystem).
# The file is written once before the tests, so reads hit real data.

FIO_FILE=
fio_run() { # name rw bs iodepth seconds [extra...]
    local name=$1 rw=$2 bs=$3 depth=$4 t=$5
    shift 5
    fio --name="$name" --filename="$FIO_FILE" --size="$FIO_SIZE" --direct=1 --ioengine=libaio --rw="$rw" --bs="$bs" \
        --iodepth="$depth" --numjobs=1 --time_based --runtime="$t" --ramp_time=2 --group_reporting \
        --output-format=json "$@"
}

fio_iops() { # rw bs depth seconds -> IOPS
    local dir=read
    [[ $1 == *write ]] && dir="write"
    fio_run x "$1" "$2" "$3" "$4" | jq ".jobs[0].$dir.iops | floor"
}

fio_mbs() { # rw bs depth seconds -> MB/s
    local dir=read
    [[ $1 == *write ]] && dir="write"
    fio_run x "$1" "$2" "$3" "$4" | jq ".jobs[0].$dir.bw_bytes / 1000000 | . * 10 | round / 10"
}

# 4K writes with fdatasync after each one, like database commits. Prints IOPS and saves the p99 sync latency.
fio_sync() { # seconds
    local out
    out=$(fio_run x write 4k 1 "$1" --fdatasync=1)
    jq '.jobs[0].sync.lat_ns.percentile["99.000000"] / 1000 | round' <<<"$out" >>"$WORK/sync_p99"
    jq '.jobs[0].write.iops | floor' <<<"$out"
}

test_disk() {
    local t
    t=$(secs 15 5)
    FIO_SIZE=$([[ $QUICK == 1 ]] && echo 512M || echo 2G)
    FIO_FILE="$WORK/fio.bin"
    log "disk: laying out a $FIO_SIZE test file"
    fio --name=layout --filename="$FIO_FILE" --size="$FIO_SIZE" --rw=write --bs=1M --direct=1 --ioengine=libaio \
        --output=/dev/null || { skipped disk "cannot write $FIO_FILE"; return; }

    measure disk disk_rand_read_4k "{\"rw\":\"randread\",\"bs\":\"4k\",\"iodepth\":32,\"size\":\"$FIO_SIZE\",\"time\":$t}" fio_iops randread 4k 32 "$t"
    measure disk disk_rand_write_4k "{\"rw\":\"randwrite\",\"bs\":\"4k\",\"iodepth\":32,\"size\":\"$FIO_SIZE\",\"time\":$t}" fio_iops randwrite 4k 32 "$t"
    : >"$WORK/sync_p99"
    measure disk disk_sync_write_4k "{\"rw\":\"write\",\"bs\":\"4k\",\"iodepth\":1,\"fdatasync\":1,\"time\":$t}" fio_sync "$t"
    # shellcheck disable=SC2046
    record disk disk_sync_write_4k_p99 "{\"rw\":\"write\",\"bs\":\"4k\",\"iodepth\":1,\"fdatasync\":1,\"time\":$t}" 0 $(cat "$WORK/sync_p99")
    measure disk disk_seq_read_1m "{\"rw\":\"read\",\"bs\":\"1m\",\"iodepth\":8,\"size\":\"$FIO_SIZE\",\"time\":$t}" fio_mbs read 1m 8 "$t"
    measure disk disk_seq_write_1m "{\"rw\":\"write\",\"bs\":\"1m\",\"iodepth\":8,\"size\":\"$FIO_SIZE\",\"time\":$t}" fio_mbs write 1m 8 "$t"
    rm -f "$FIO_FILE" "$WORK/sync_p99"
}
