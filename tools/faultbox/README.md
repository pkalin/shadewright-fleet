# faultbox

A small workload that fails on request in exact, known ways, so a scenario's ground truth is written by the thing
that caused the failure (epic pkalin/shadewright#958, decisions of 2026-11-21). One static Go binary, standard library only,
on a distroless image that runs as a non-root user with a read-only root filesystem. The image pipeline and the
manifests that run it come with later tasks.

## Faults

| Fault | Flag (start) | Endpoint (run time) | What happens |
| --- | --- | --- | --- |
| memory | `--memory-mb` | `POST /memory?mb=200[&cross=true]` | allocates and holds the memory, every page touched; above the limit the container is OOMKilled |
| cpu | `--cpu-millicores`, `--cpu-seconds` (default 300) | `POST /cpu?millicores=100&seconds=300[&cross=true]` | burns that much CPU for that long |
| disk | `--disk-mb` | `POST /disk?mb=100[&cross=true]` | writes one file of that size into `--disk-dir` (an emptyDir); above the ephemeral-storage limit the kubelet evicts the pod |
| crash | `--crash-code`, `--crash-after` | `POST /crash?code=1` | exits with the code (1 to 255); an endpoint crash waits 100 ms so the caller gets its answer |
| ready | `--ready=false` | `POST /ready?state=false` | `/readyz` answers 503 |
| errors | `--error-rate` | `POST /errors?rate=0.3` | that share of requests to `/` get HTTP 500, drawn from the seed (the same seed gives the same sequence) |
| latency | `--latency-ms` | `POST /latency?ms=800` | requests to `/` wait that long first |
| log | `--log-pattern`, `--log-per-second` (default 1), `--log-seconds` (default 60) | `POST /log?pattern=noise&per_second=1&seconds=60` | writes lines of a fixed set: `noise`, `misleading` (errors pointing at causes the scenario did not create) or `injection` (text aimed at a model, with fake credentials for redaction) |
| reset | | `POST /reset` | ends every fault: frees the memory, removes the disk file, stops cpu, log and a pending crash, sets readiness, errors and latency back |

Setting a size to 0 (`mb=0`) releases the memory or removes the disk file. A new cpu or log fault replaces the one
in force.

Without a token, `/healthz` (always 200), `/readyz` and `/` (the workload's own endpoint, where the errors and
latency faults act) answer anyone.

## Ground truth

Every applied fault is one JSON line on stdout, written before the fault is carried out, so a fault that kills the
process is on record first:

```json
{"time":"...","level":"INFO","msg":"fault applied","event":"fault","fault":"memory","source":"start","seed":"77","scenario":"oom-start","params":{"mb":100,"cross":true}}
```

A scorer reads only JSON lines with `"event":"fault"`. Other events: `fault_refused` (over a cap or out of range,
nothing applied), `fault_failed` (recorded, then failed, for example a disk write error), `start_refused` (the
process exits 2 and applies nothing), `request_refused` (a control call without a valid token; the reason never
holds the token) and `serving`. The lines of the log fault are plain text and never start with `{`, so none can
pass for a record.

The seed comes from `--seed` (required when a fault is set at start) or from a `seed` query parameter, which
overrides it for that call. A call with neither is refused. Seeds are 1 to 64 characters of `A-Z a-z 0-9 . _ : -`.

## Start configuration

Faults set at start come from flags or from `--config <file>`, a file of `key=value` lines with the same names as
the flags (blank lines and `#` comments allowed), normally a mounted ConfigMap, so a scenario is declared in Git:

```
seed=77
scenario=oom-start
memory-mb=200
cross-limits=true
```

A flag on the command line wins over the file. The file may set only the faults, `seed`, `scenario` and
`cross-limits`: never `token-file`, `disk-dir`, `listen` or the limits. An unknown or repeated key, or a sub-flag
without its fault (`cpu-seconds` without `cpu-millicores`), refuses the start. All start faults are checked before
the first is applied; the crash is applied last.

## Caps

The binary refuses any size above its cap (HTTP 422 at an endpoint, exit 2 at start). The caps come from the pod's
limits, passed with the Downward API: `--limit-memory-mb`, `--limit-disk-mb`, `--limit-cpu-millicores`. For memory
the cgroup limit is read as well (`/sys/fs/cgroup/memory.max`, or v1) and the lower of the two is used.

- Without crossing: memory and disk up to three quarters of the limit, CPU up to the limit. With no known limit:
  64 MiB of memory, 64 MiB of disk, 500 millicores.
- With `--cross-limits` (start) or `cross=true` (endpoint): up to twice the limit, so a scenario can get a real
  OOMKill or eviction while a wrong limit flag still bounds the damage. Crossing needs a known limit; with none it
  is refused, because the size would press the node instead of the pod.
- Hard ceilings whatever the limits say: 4096 MiB of memory or disk, 4000 millicores, 3600 seconds of cpu or log,
  60000 ms of latency, 100 log lines per second.

## Control endpoints and the token

The control endpoints take `POST` only and need `Authorization: Bearer <token>`. The token is read from
`--token-file` (a mounted Secret) at each call, so a rotated Secret needs no restart, and compared in constant time
over SHA-256 digests. With no `--token-file`, a missing or unreadable file, or a token shorter than 16 bytes, every
control call is refused with 401. The token check comes before anything else in the call is looked at.

The manifests (a later task) add the rest of the safety: no Ingress, a NetworkPolicy that admits only the scenario
runner, a low PriorityClass and limits on the pod.

## Build and check

```bash
make faultbox-lint faultbox-test   # gofmt, go vet, unit tests with the race detector
docker build -t faultbox tools/faultbox
docker run --rm --read-only --memory 64m faultbox --seed 77 --memory-mb 100 --cross-limits   # OOMKilled, exit 137
```

`Dockerfile` pins the Go builder and the distroless base by digest; bump the tag and the digest together.
