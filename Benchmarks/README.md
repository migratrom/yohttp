# Benchmark suite

Run the reproducible release-mode suite with:

```sh
Scripts/benchmark.sh
```

It requires [`wrk`](https://github.com/wg/wrk). Each case uses loopback HTTP/1.1 keep-alive connections and reports `wrk --latency`'s p99, throughput, and baseline/post-run RSS. Every case runs in a fresh server process, so its memory result is not contaminated by earlier workloads. Raw results are written under `.build/benchmark-results/`, keeping generated measurements out of the working tree.

The suite drives a duplicated copy of the todo example API (`@Route` macros, JSON encode/decode, actor store, streaming echo). Seeded todos use fixed UUIDs so GET/PATCH URLs stay stable across requests. Request logging is omitted so stdout does not dominate p99.

The cases:

- `health`: `GET /health` — small JSON response through the router and request-id middleware.
- `list`: `GET /api/todos?completed=false` — query params, actor list, JSON encode.
- `get`: `GET /api/todos/<seed>` — path param, actor lookup, JSON encode.
- `create`: `POST /api/todos` — JSON decode, validation, actor insert, JSON encode. The in-memory store is unbounded, so RSS grows with insert volume; seed IDs are never deleted.
- `patch`: `PATCH /api/todos/<seed>` — JSON decode, actor update, JSON encode against a fixed seed id.
- `echo`: `POST /api/echo` — 256 KiB body streamed chunk-by-chunk to the response.

For a longer run, for example:

```sh
DURATION=60s CONNECTIONS=128 THREADS=8 Scripts/benchmark.sh
```

Use `CASES="health get"` to run a subset while investigating a regression.

`HEAP_SNAPSHOT=1` captures live heap summaries plus physical-footprint/peak data after each case on macOS. `ALLOCATIONS_TRACE=1` creates an Instruments Allocations trace for the health case. Instrumentation changes timing, so use that trace to study allocation sites and a normal run to compare p99 latency.

RSS measures resident memory at the end of a case, rather than total bytes allocated over its lifetime. The latter is intentionally profiled separately because allocation instrumentation distorts latency measurements.

The default suite uses one server event loop. To run the same workloads with one
event loop per physical CPU core on macOS or Linux, use:

```sh
Scripts/benchmark-physical-cores.sh
```

The wrapper reads the platform's physical-core topology, passes that count to
the server, and records the event-loop count in the summary. Set
`EVENT_LOOP_COUNT` when running `Scripts/benchmark.sh` directly to benchmark
another positive loop count or to run on another platform.
