# VPScast bench

The benchmark [VPScast](https://vpscast.com) runs on every VPS plan it lists. It measures CPU, disk, a web server, a
database, a Docker build, network speed, and latency to cloud regions and crypto exchange APIs.

```bash
curl -fsSL https://github.com/vpscast/bench/releases/latest/download/run.sh | bash
```

A full run takes 12 to 15 minutes. You need Linux on amd64 or arm64, 4 GB of free disk, Docker, and root or sudo. If
Docker is not installed, the script asks before installing it with the official script from get.docker.com. Use
`--yes` to skip the question.

Options go after `bash -s --`:

```bash
curl -fsSL https://github.com/vpscast/bench/releases/latest/download/run.sh | bash -s -- --quick --only cpu,disk
```

To read the script first, download it and run it as a file:

```bash
curl -fsSLO https://github.com/vpscast/bench/releases/latest/download/run.sh
less run.sh
bash run.sh --yes
```

Results go to `./vpscast-bench-<time>/`:

- `result.json` with the raw values: samples, median, p10 and p90 for every metric, steal time, test and tool
  versions, the runner release and image digest, and the environment (CPU model, hypervisor, kernel, disk)
- `mtr-*.txt` with the route to two public resolvers

## Options

| Option | |
| --- | --- |
| `--quick` | about 4 minutes, one repeat, shorter tests; for a quick check, not comparable with full runs |
| `--only cpu,disk` | run some tests only: `cpu`, `disk`, `web`, `db`, `build`, `network`, `latency` |
| `--repeats <n>` | repeat each test n times instead of 3 |
| `--yes` | install Docker without asking |
| `--out <dir>` | where to put the results |
| `--image <ref>` | run another image, for example a test build; the same as `VPSCAST_BENCH_IMAGE=<ref>` |
| `--build` | build the image from this checkout instead of pulling it (for development) |
| `--keep` | keep the work directory (`/var/tmp/vpscast-bench-work`) |

## Results

At the end the script prints a summary: each metric with its median, and the tests that were skipped and why.

```
cpu_sysbench_1t               1505.0 events/s
disk_sync_write_4k            4120 IOPS
net_down cloudflare           2310.4 Mbit/s
net_down_near leaseweb-fra    1870.2 Mbit/s
latency_tcp aws-eu-central-1  1.8 ms
time, s: cpu 95, disk 160, web 110, db 140, build 210, network 60, latency 45
```

`result.json` has the same values in full:

| Field | |
| --- | --- |
| `runner` | release version, git commit, image and its digest |
| `tests` | the version of each test that ran |
| `quick`, `repeats` | the run mode |
| `environment` | CPU model and flags, vCPU, RAM, hypervisor, kernel, OS, disk |
| `results[]` | one entry per metric and target: `metric`, `target`, `unit`, `better` (`higher` or `lower`), `samples`, `median`, `p10`, `p90`, `steal_pct`, `params`, `tool`, `tool_version` |
| `skipped[]` | tests that did not run, with the reason |
| `durations` | seconds per test |

A missing `median` means every attempt failed, for example a speed test endpoint refused the connection. It is not
a zero. On an IPv6-only server the network and latency values are missing: the tests use IPv4 only.

### Metrics

| Metric | Unit | Better | What |
| --- | --- | --- | --- |
| `cpu_sysbench_1t`, `cpu_sysbench_mt` | events/s | higher | sysbench CPU, one thread and all vCPUs |
| `cpu_7zip_1t`, `cpu_7zip_mt` | MIPS | higher | 7-Zip compression, one thread and all vCPUs |
| `disk_rand_read_4k`, `disk_rand_write_4k` | IOPS | higher | random 4K reads and writes, queue depth 32 |
| `disk_sync_write_4k` | IOPS | higher | 4K writes with a flush after each one, like a database commit |
| `disk_sync_write_4k_p99` | µs | lower | the 99th percentile latency of those writes |
| `disk_seq_read_1m`, `disk_seq_write_1m` | MB/s | higher | sequential reads and writes |
| `web_static`, `web_php` | req/s | higher | nginx static page, Laravel page on PHP-FPM |
| `db_pgbench_rw`, `db_pgbench_ro` | TPS | higher | PostgreSQL pgbench, read-write and select-only |
| `docker_build_laravel` | s | lower | build of a Laravel app image without cache |
| `net_down`, `net_up` | Mbit/s | higher | Cloudflare speed test, target `cloudflare` |
| `net_down_near` | Mbit/s | higher | download from the nearest neutral point outside the server's network (`near.txt`); the target names it, `params` hold its connect time |
| `net_down_point` | Mbit/s | higher | one stream from a fixed point per continent; compares routes, not a speed figure |
| `latency_tcp` | ms | lower | TCP connect time to a cloud region or resolver |
| `latency_api` | ms | lower | request time to an exchange API on an open connection |

### Reading the numbers

- `steal_pct` above 1 means other guests on the host took CPU time during the test. The value may be low; run again
  later.
- Compare your run with numbers on VPScast only when the major test versions match (`tests` in `result.json`) and
  both are full runs. A `--quick` run is shorter and repeats once; it is for a quick check only.
- The web, database and build tests run everything on the server itself. They compare plans; they do not size a
  production setup.

## What it does on your server

- Runs one container from `ghcr.io/vpscast/bench` with host networking and no resource limits.
- Writes up to about 3 GB of test files to `/var/tmp/vpscast-bench-work` and deletes them at the end.
- Mounts the Docker socket for the build test, and only when that test runs. It builds an image and deletes it, and pulls
  `php:8.5-cli-trixie` if it is not there yet. BuildKit keeps its build cache, `docker builder prune` removes it.
- Downloads and uploads a few GB from public speed test endpoints.

The `run.sh` attached to a release (`releases/download/vX.Y.Z/run.sh`) always runs the image of that release, pinned
by digest.

[METHODOLOGY.md](METHODOLOGY.md) explains what is measured, how the score is computed and how versions work. Latency
targets and download points are listed in `targets.txt`, `near.txt` and `downloads.txt`. Pull requests are welcome.

Code: MIT. Results published by VPScast: CC BY 4.0.
