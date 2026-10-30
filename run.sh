#!/usr/bin/env bash
# vpscast-bench: runs the VPScast benchmark on this server.
#
#   curl -fsSL https://github.com/vpscast/bench/releases/latest/download/run.sh | bash
#   curl -fsSL ... | bash -s -- --quick          # about 4 min, for a quick check only
#
# Options: --quick, --only cpu,disk,..., --repeats <n> (3 by default), --yes (install Docker without asking), --out
# <dir>, --image <ref>, --build (build the image from this checkout), --keep (keep the work directory).
# Results go to ./vpscast-bench-<time>/.
set -euo pipefail

VERSION=1.3.0
# In the repository this is the tag. The release workflow replaces it with the image digest in the published run.sh.
IMAGE=ghcr.io/vpscast/bench:$VERSION
IMAGE=${VPSCAST_BENCH_IMAGE:-$IMAGE}

YES=0 BUILD=0 KEEP=0 OUT='' ONLY='' ARGS=()
TESTS=(cpu disk web db build network latency)
while (($#)); do
    case $1 in
        --yes | -y) YES=1 ;;
        --image) IMAGE=$2; shift ;;
        --build) BUILD=1 ;;
        --keep) KEEP=1 ;;
        --out) OUT=$2; shift ;;
        --quick) ARGS+=("$1") ;;
        --only) ONLY=$2; ARGS+=("$1" "$2"); shift ;;
        --repeats) ARGS+=("$1" "$2"); shift ;;
        -h | --help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Checked here as well as in the image, so a typo does not wait for the image to download.
IFS=, read -ra only <<<"$ONLY"
for test in "${only[@]}"; do
    [[ " ${TESTS[*]} " == *" $test "* ]] || die "no such test: $test (tests: ${TESTS[*]})"
done
# Only the build test talks to the server's Docker, so only it gets the Docker socket.
SOCKET=()
[[ -z $ONLY || ",$ONLY," == *,build,* ]] && SOCKET=(-v /var/run/docker.sock:/var/run/docker.sock)

[[ $(uname -s) == Linux ]] || die "Linux only: the tests read the server's own CPU, disk and network."
SUDO=
[[ $EUID -eq 0 ]] || SUDO=sudo

# All tools run from one image, so every server uses the same versions. Docker is installed only if the user agrees.
if ! command -v docker >/dev/null; then
    say "Docker is not installed. The benchmark runs its tools in a Docker image, so every server gets the same versions."
    if [[ $YES == 0 ]]; then
        [[ -r /dev/tty ]] || die "no terminal to ask on: install Docker yourself, or pass --yes"
        read -rp "Install Docker with the official script from get.docker.com? [y/N] " answer </dev/tty
        [[ $answer == [yY]* ]] || die "Docker is needed. Install it (https://docs.docker.com/engine/install/) and run again."
    fi
    # A fresh cloud server installs updates at boot, and the install script fails while they hold the package lock.
    # Wait for cloud-init and for apt or dpkg to finish (10 minutes at most), then try once more if it still fails.
    if command -v cloud-init >/dev/null; then
        say "Waiting for cloud-init to finish"
        timeout 600 $SUDO cloud-init status --wait >/dev/null 2>&1 || true
    fi
    for ((i = 0; i < 120; i++)); do
        pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null || break
        ((i == 0)) && say "Waiting for the system's package updates to finish"
        sleep 5
    done
    curl -fsSL https://get.docker.com | $SUDO sh || {
        say "The Docker install failed, trying again in 30 s"
        sleep 30
        curl -fsSL https://get.docker.com | $SUDO sh
    }
fi
DOCKER="docker"
docker info >/dev/null 2>&1 || DOCKER="$SUDO docker"
$DOCKER info >/dev/null 2>&1 || die "cannot talk to the Docker daemon"

# Work directory on the root filesystem, so the disk test does not write to Docker's overlay.
WORK=/var/tmp/vpscast-bench-work
OUT=${OUT:-$PWD/vpscast-bench-$(date -u +%Y%m%d-%H%M%S)}
mkdir -p "$WORK" "$OUT"
OUT=$(cd "$OUT" && pwd)
free=$(df -BG --output=avail "$WORK" | tail -1 | tr -dc 0-9)
# The image takes 0.6 GB, the largest test 2 GB (the disk test's file); each test removes its files when it ends.
((free >= 4)) || die "need 4 GB free in $WORK, have ${free} GB"

if [[ $BUILD == 1 ]]; then
    IMAGE=vpscast-bench:local
    say "Building the image from $(dirname "$0")"
    $DOCKER build -q -t "$IMAGE" "$(cd "$(dirname "$0")" && pwd)" >/dev/null
else
    if ! $DOCKER image inspect "$IMAGE" >/dev/null 2>&1; then
        say "Pulling $IMAGE"
        $DOCKER pull -q "$IMAGE" >/dev/null
    fi
fi
DIGEST=$($DOCKER image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$IMAGE")

cleanup() { [[ $KEEP == 1 ]] || rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# Host network, so there is no NAT. No CPU or memory limits.
say "Running; results go to $OUT"
$DOCKER run --rm --network host \
    -v "$WORK:/work" -v "$OUT:/out" "${SOCKET[@]}" \
    -e HOST_OS="$(. /etc/os-release && echo "$PRETTY_NAME")" -e RUNNER_IMAGE="$IMAGE" -e RUNNER_DIGEST="$DIGEST" \
    -e OWNER="$(id -u):$(id -g)" \
    "$IMAGE" "${ARGS[@]}"

say "Done: $OUT/result.json"
