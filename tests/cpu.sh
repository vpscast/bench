# CPU tests: sysbench (prime numbers) and the 7-Zip benchmark (compression), on one thread and on all vCPUs.

sysbench_cpu() { # threads seconds
    sysbench cpu --cpu-max-prime=20000 --threads="$1" --time="$2" run | awk '/events per second/{print $4}'
}

# Total 7-Zip rating in MIPS. The dictionary size is fixed, because by default 7-Zip picks it based on RAM. 4 MB takes
# about 28 MB per thread, so it fits a 512 MB plan (16 MB took 110 MB per thread and was killed there).
sevenzip() { # threads
    7z b -mmt"$1" -md22 | awk '/^Tot:/{print $4}'
}

test_cpu() {
    local t
    t=$(secs 10 5)

    measure cpu cpu_sysbench_1t "{\"threads\":1,\"cpu_max_prime\":20000,\"time\":$t}" sysbench_cpu 1 "$t"
    measure cpu cpu_sysbench_mt "{\"threads\":$NPROC,\"cpu_max_prime\":20000,\"time\":$t}" sysbench_cpu "$NPROC" "$t"
    measure cpu cpu_7zip_1t '{"threads":1,"dictionary":"4M"}' sevenzip 1
    measure cpu cpu_7zip_mt "{\"threads\":$NPROC,\"dictionary\":\"4M\"}" sevenzip "$NPROC"
}
