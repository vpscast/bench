# VPScast bench

The benchmark [VPScast](https://vpscast.com) runs on every VPS plan it lists. It measures CPU, disk, a web server, a
database, a Docker build, network speed, and latency to cloud regions and crypto exchange APIs.

```bash
curl -fsSL https://github.com/vpscast/bench/releases/latest/download/run.sh | bash
```

A full run takes 12 to 15 minutes. You need Linux, 6 GB of free disk and Docker. If Docker is not installed, the
script asks before installing it with the official script from get.docker.com. Use `--yes` to skip the question.

Results go to `./vpscast-bench-<time>/`:

- `result.json` with the raw values: samples, median, p10 and p90 for every metric, steal time, test and tool
  versions, the runner release and image digest, and the environment (CPU model, hypervisor, kernel, disk)
- `mtr-*.txt` with the route to two public resolvers

## Options

| Option | |
| --- | --- |
| `--quick` | about 4 minutes, one repeat, shorter tests; for a quick check, not comparable with full runs |
| `--only cpu,disk` | run some tests only: `cpu`, `disk`, `web`, `db`, `build`, `network`, `latency` |
| `--yes` | install Docker without asking |
| `--out <dir>` | where to put the results |
| `--build` | build the image from this checkout instead of pulling it |
| `--keep` | keep the work directory (`/var/tmp/vpscast-bench-work`) |

## What it does on your server

- Runs one container from `ghcr.io/vpscast/bench` with host networking and no resource limits.
- Writes up to about 3 GB of test files to `/var/tmp/vpscast-bench-work` and deletes them at the end.
- Mounts the Docker socket for the build test. That test builds an image and deletes it, and pulls
  `php:8.5-cli-trixie` if it is not there yet. BuildKit keeps its build cache, `docker builder prune` removes it.
- Downloads and uploads a few GB from public speed test endpoints.

The `run.sh` attached to a release (`releases/download/vX.Y.Z/run.sh`) always runs the image of that release, pinned
by digest.

[METHODOLOGY.md](METHODOLOGY.md) explains what is measured, how the score is computed and how versions work. Latency
targets and download files are listed in `targets.txt` and `downloads.txt`. Pull requests are welcome.

Code: MIT. Results published by VPScast: CC BY 4.0.
