# Changelog

Runner releases and the test versions in each. A major test version changes the numbers, so results are compared
only within one; see Versions in [METHODOLOGY.md](METHODOLOGY.md).

## 1.3.0

cpu 2.0.0, disk 1.0.0, web 2.0.1, db 2.0.0, build 1.0.1, network 2.0.1, latency 3.0.0

- cpu 2.0.0: 7-Zip with a 4 MB dictionary (`-md22`) instead of 16 MB. 16 MB took about 110 MB per thread and was
  killed on 512 MB plans; 4 MB takes about 28 MB. The rating is within a few percent.
- db 2.0.0: the pgbench scale is at least the client count, so above 25 vCPU the clients no longer wait on each
  other's branch rows, and `max_connections` follows the client count (200 was too few above 100 vCPU). The test is
  skipped with a reason if the disk cannot hold that scale. Up to 25 vCPU the parameters are unchanged.
- latency 3.0.0: TCP connect times no longer include starting processes, which added 4 to 7 ms on a fast desktop and
  more on a slow vCPU. Exchange API times count 2xx answers only; a 403, 429 or 451 came from the CDN node.
- network 2.0.1: the Cloudflare upload is read from the file as it goes instead of being loaded into memory. The
  nearest point's connect time is measured as in latency 3.0.0. `near.txt` adds 11 points in South America, India,
  Africa and the Middle East (Linux mirrors of an exchange point, carriers, datacenters and research networks).
- web 2.0.1, build 1.0.1: the Laravel app is a fixed skeleton release with locked dependencies (the same as in the
  1.2.0 image), and its Laravel and Composer versions are checked in CI.
- run.sh waits for cloud-init and boot-time package updates before installing Docker, asks for 4 GB of free disk
  instead of 6, checks `--only` before pulling the image, and mounts the Docker socket only when the build test
  runs.
- Steal time leaves out guest time, which is already part of user time. The sync write p99 records the steal time of
  its runs.
- The release checks the tools of the pushed image itself, not of a second build.

## 1.2.0

cpu 1.0.0, disk 1.0.0, web 2.0.0, db 1.0.0, build 1.0.0, network 2.0.0, latency 2.0.0

- network 2.0.0: `net_down_near` picks from `near.txt`, speed test files of hosts that are not among the compared
  providers (Leaseweb, Clouvider), over plain HTTP. A point is skipped when its owner runs the server's network,
  matched by the AS holder. The download is repeated like the other tests. `params` record the point's connect time
  and the server's network.
- network 2.0.0, latency 2.0.0: all network and latency tests use IPv4.

## 1.1.0

cpu 1.0.0, disk 1.0.0, web 2.0.0, db 1.0.0, build 1.0.0, network 1.1.0, latency 1.0.0

- network 1.1.0: new metric `net_down_near`, a download from the nearest point outside the server's AS, for a speed
  figure when Cloudflare refuses the IP. `net_up` no longer fails when the deadline cuts an upload.
- web 2.0.0: the wrk client grows with the server, a thread per 4 vCPU (2 to 16) and 4 connections per PHP-FPM worker
  (64 to 512). Up to 8 vCPU the parameters are unchanged.

## 1.0.1

cpu 1.0.0, disk 1.0.0, web 1.0.1, db 1.0.0, build 1.0.0, network 1.0.1, latency 1.0.0

- network 1.0.1: after a 429 the Cloudflare test waits as long as Retry-After asks and tries once more.
- web 1.0.1: nginx asks for 1024 connections, within the container's open file limit.

## 1.0.0

All tests 1.0.0.
