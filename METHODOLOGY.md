# Methodology

This file describes what the runner measures, how, and how VPScast turns the raw numbers into a score. VPScast runs
the same script on every plan it lists, so a run on your own server gives numbers you can compare with ours.

## Setup

All tools come from one Docker image, built from Ubuntu 26.04 LTS packages and pinned by digest. A tool update that
can change the numbers gets a new test version (see Versions below).

The container uses host networking and has no CPU or memory limits. The disk test writes with direct I/O to a
directory on the root filesystem, mounted into the container, so it does not go through Docker's overlay. In this
setup Docker adds no measurable overhead.

Each test runs 3 times in a row and we keep the median. Network throughput runs once. The spread shown on the site
(p10 to p90) comes from runs on different days. Three repeats a minute apart only show the noise of that minute.

Steal time is read from `/proc/stat` for every test, so a busy neighbour on the same host is visible in the data.

Every run records the CPU model and flags, the hypervisor, the kernel and the disk. The CPU shown on a plan page
comes from these records, not from the provider's description.

A full run takes 12 to 15 minutes and moves a few GB over the network. Network tests only use public speed test
files and public `ping`/`time` API endpoints.

## Tests

| Test | Metric | Tool | Parameters |
| --- | --- | --- | --- |
| CPU, one thread | events/s | sysbench 1.0.20 | `cpu --cpu-max-prime=20000`, 10 s |
| CPU, all vCPUs | events/s | sysbench | same, `--threads=<vCPU>` |
| Compression, one thread | MIPS | 7-Zip 26.00 | `7z b -mmt1 -md24` |
| Compression, all vCPUs | MIPS | 7-Zip | `7z b -mmt<vCPU> -md24` |
| Disk random read | IOPS | fio 3.41 | 4K, QD32, libaio, direct, 2 GB file, 15 s |
| Disk random write | IOPS | fio | 4K, QD32 |
| Disk sync write | IOPS, p99 µs | fio | 4K, QD1, `fdatasync` after each write |
| Disk sequential | MB/s | fio | 1M, QD8, read and write |
| Web, static | req/s | nginx 1.28, wrk 4.1 | 10 KB page, 2 threads, 64 connections, 10 s |
| Web, PHP | req/s | PHP-FPM 8.5 with OPcache, wrk | Laravel 13 welcome page, 2 workers per vCPU |
| Database | TPS | PostgreSQL 18, pgbench | scale 50, 2 clients per vCPU, 20 s, read-write and select-only |
| Docker build | s | Docker with BuildKit | Laravel app image, see below |
| Download | Mbit/s | curl | Cloudflare speed test, 4 streams, 8 s or 1 GB |
| Upload | Mbit/s | curl | Cloudflare speed test, 4 streams, 8 s or 1 GB |
| Download, route | Mbit/s | curl | one file per continent (`downloads.txt`), 1 stream, 6 s |
| Latency, regions | ms | TCP connect | cloud regions and public resolvers (`targets.txt`), 10 samples |
| Latency, exchange APIs | ms | curl | request on an open connection, 10 samples |
| Route | | mtr | to 1.1.1.1 and 8.8.8.8, saved as text |

Notes on some of them:

- 7-Zip picks its dictionary size from the amount of RAM by default. We fix it at 16 MB so every plan runs the
  same test.
- The sync write test is what a database commit looks like: one 4K write, then a flush.
- The web and database tests run the client on the same server. That is the same for every plan, and the numbers are
  meant for comparing plans, not for sizing a production setup.
- The Docker build compiles a few PHP extensions from source, copies a Laravel app in and builds its caches. It uses
  no cache, and the base image is pulled before the timer starts, so the network does not count.
- Cloudflare's speed test starts answering 429 after a few GB from one IP. We use it once per run, up to 1 GB, and
  record a refusal as a missing value, not as zero.
- Most exchanges are behind a CDN. A ping or a TCP connect only reaches the nearest CDN node and looks fast from
  anywhere. The request itself goes on to the exchange, so for exchanges we time the request on an already open
  connection.
- Memory bandwidth is not measured. `sysbench memory` reports hundreds of GB/s, which is cache speed, not RAM. Memory
  speed still affects the compression, database and PHP results.

## Score

The runner does not compute a score. `result.json` only has raw values, and VPScast computes the score from the
results of all plans. Changing the formula does not need a new runner.

The approach follows existing benchmarks. SPEC CPU and Geekbench divide each result by a fixed reference and combine
the ratios with a geometric mean. VPSBenchmarks gives its categories equal weight and keeps price out of the score.
Cloud Mercato reports performance per price as a separate number.

1. Each metric is divided by its reference value, or the reference by the metric for times and latencies.
2. A category index is the geometric mean of its ratios, times 100. The categories are:
   - CPU: sysbench and 7-Zip, one thread and all vCPUs
   - Disk: random read, random write, sync write, sequential read and write
   - Applications: static web, PHP, both database tests, Docker build
   - Network: download and upload
3. The score is the geometric mean of the four category indexes. 100 means equal to the reference.
4. The reference values are the medians of the first full round of runs in the 2 vCPU class. They are published on
   the methodology page and stay fixed while the test versions stay the same.
5. Performance per dollar is the score divided by the full monthly price in USD.
6. On a plan page each metric is also compared with the median of its class: same vCPU count, shared or dedicated.

If a metric is missing, its category is computed from the rest and the run is marked partial. Partial runs are not
ranked. Latency is not part of the score, since it depends on where you are and not on the server.

## Versions

`manifest.json` holds all versions and is copied into every `result.json`.

Each test has its own version, for example `disk 1.0.0`. Results are compared only within one major version of a
test. A patch release does not change the numbers, a minor one adds a metric, and a major one changes the numbers,
for example a new tool version or different parameters. So a new fio only affects disk results. After a major change
the old and new versions run side by side on the same plans for a while, and the changelog shows the difference.

The runner itself is released with a git tag such as `v1.2.0`. A release is a fixed set of test versions.

The image digest and the git commit tell exactly what ran. CI builds the image from the tagged commit, checks that the
tool versions match `manifest.json`, and publishes a `run.sh` pinned to that digest. The build log is public.

## Licences

Code: MIT. Results published by VPScast: CC BY 4.0.
