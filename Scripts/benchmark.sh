#!/usr/bin/env bash
# Reproducible latency and resident-memory benchmark for the todo API surface.
set -euo pipefail

EVENT_LOOP_COUNT=7
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
duration="${DURATION:-20s}"
connections="${CONNECTIONS:-128}"
threads="${THREADS:-4}"
event_loop_count="${EVENT_LOOP_COUNT:-1}"
port="${PORT:-8081}"
wrk_bin="${WRK_BIN:-wrk}"
cases="${CASES:-health list get create patch echo}"
seed_todo_id="00000000-0000-0000-0000-000000000001"
timestamp="$(date +%Y%m%d-%H%M%S)"
results_dir="${RESULTS_DIR:-$root_dir/.build/benchmark-results/$timestamp}"
server_pid=""

usage() {
    cat <<'EOF'
Usage: Scripts/benchmark.sh

Required: wrk (set WRK_BIN to override its path).

Environment:
  DURATION=20s          Duration of each measured case.
  CONNECTIONS=64        Concurrent keep-alive connections.
  THREADS=4             wrk worker threads.
  EVENT_LOOP_COUNT=1    Server event loops.
  CASES="health get"    Space-separated subset of benchmark cases.
  PORT=8081             Loopback port for the benchmark server.
  RESULTS_DIR=...       Directory for raw wrk output and memory snapshots.
  HEAP_SNAPSHOT=1       On macOS, capture heap summaries after each case.
  ALLOCATIONS_TRACE=1   On macOS, collect an Instruments Allocations trace for
                        the health case. This perturbs latency and is
                        intentionally not included in the latency comparison.
EOF
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

for command in swift "$wrk_bin" curl ps; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

if ! [[ "$event_loop_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "EVENT_LOOP_COUNT must be a positive integer" >&2
    exit 1
fi

mkdir -p "$results_dir"

cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" >/dev/null 2>&1; then
        kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" 2>/dev/null || true
    fi
    server_pid=""
}
trap cleanup EXIT INT TERM

echo "Building yohttp-benchmark in release mode..."
swift build -c release --product yohttp-benchmark --package-path "$root_dir"
binary="$root_dir/.build/release/yohttp-benchmark"

start_server() {
    local name="$1"
    echo "Starting a fresh server for $name..."
    YOHTTP_BENCHMARK_PORT="$port" \
    YOHTTP_BENCHMARK_EVENT_LOOP_COUNT="$event_loop_count" \
    "$binary" >"$results_dir/$name.server.log" 2>&1 &
    server_pid=$!

    for _ in $(seq 1 100); do
        if curl --silent --fail "http://127.0.0.1:$port/health" >/dev/null; then
            return
        fi
        sleep 0.1
    done
    if ! kill -0 "$server_pid" >/dev/null 2>&1; then
        echo "Benchmark server exited before it became ready:" >&2
        cat "$results_dir/$name.server.log" >&2
    else
        echo "Benchmark server did not become ready; see $results_dir/$name.server.log" >&2
    fi
    exit 1
}

memory_snapshot() {
    local name="$1"
    local phase="$2"
    ps -o pid=,rss=,command= -p "$server_pid" >"$results_dir/$name.$phase.rss.txt"
    if [[ "${HEAP_SNAPSHOT:-0}" == "1" && "$(uname -s)" == "Darwin" ]]; then
        heap -s -H "$server_pid" >"$results_dir/$name.$phase.heap.txt" 2>&1 || true
    fi
}

run_case() {
    local name="$1"
    local path="$2"
    local script="${3:-}"
    local trace_pid=""

    start_server "$name"
    memory_snapshot "$name" baseline
    local args=(-t "$threads" -c "$connections" -d "$duration" --latency)
    local warmup_args=(-t "$threads" -c "$connections" -d 5s --latency)
    if [[ -n "$script" ]]; then
        args+=(-s "$root_dir/$script")
        warmup_args+=(-s "$root_dir/$script")
    fi

    echo "Warming $name..."
    "$wrk_bin" "${warmup_args[@]}" "http://127.0.0.1:$port$path" \
        >"$results_dir/$name.warmup.wrk.txt"
    echo "Running $name..."
    if [[ "$name" == "health" && "${ALLOCATIONS_TRACE:-0}" == "1" && "$(uname -s)" == "Darwin" ]]; then
        xctrace record --template "Allocations" --output "$results_dir/health.trace" \
            --time-limit "$duration" --no-prompt --attach "$server_pid" \
            >"$results_dir/health.xctrace.log" 2>&1 &
        trace_pid=$!
        sleep 2
    fi

    "$wrk_bin" "${args[@]}" "http://127.0.0.1:$port$path" | tee "$results_dir/$name.measurement.wrk.txt"
    memory_snapshot "$name" post

    if [[ -n "$trace_pid" ]]; then
        wait "$trace_pid" || true
    fi
    cleanup
}

for case in $cases; do
    case "$case" in
    health) run_case health /health ;;
    list) run_case list "/api/todos?completed=false" ;;
    get) run_case get "/api/todos/$seed_todo_id" ;;
    create) run_case create /api/todos Benchmarks/post_create.lua ;;
    patch) run_case patch "/api/todos/$seed_todo_id" Benchmarks/post_patch.lua ;;
    echo) run_case echo /api/echo Benchmarks/post_echo.lua ;;
    *)
        echo "Unknown benchmark case: $case" >&2
        exit 1
        ;;
    esac
done

{
    echo "yohttp benchmark summary"
    echo "duration per case: $duration; connections: $connections; threads: $threads; event loops: $event_loop_count"
    echo
    for output in "$results_dir"/*.measurement.wrk.txt; do
        name="$(basename "$output" .measurement.wrk.txt)"
        printf '%s\n' "[$name]"
        awk '/Requests\/sec/ || /^[[:space:]]*99%/ { print }' "$output"
        echo
    done
    echo "RSS snapshots (KiB; fresh server for each case):"
    for output in "$results_dir"/*.post.rss.txt; do
        name="$(basename "$output" .post.rss.txt)"
        printf '%s: baseline ' "$name"
        awk '{ print $2 }' "$results_dir/$name.baseline.rss.txt"
        printf '  post '
        awk '{ print $2 }' "$output"
    done
    if compgen -G "$results_dir/*.post.heap.txt" >/dev/null; then
        echo "macOS heap physical footprint (post-run; peak):"
        for output in "$results_dir"/*.post.heap.txt; do
            name="$(basename "$output" .post.heap.txt)"
            printf '%s: ' "$name"
            awk -F: '/^Physical footprint:/ { current = $2 } /^Physical footprint \(peak\):/ { print current "; peak" $2 }' "$output"
        done
    fi
} | tee "$results_dir/summary.txt"

echo "Raw results: $results_dir"
if [[ "${ALLOCATIONS_TRACE:-0}" == "1" ]]; then
    echo "The Allocations trace perturbs health-case latency; compare its allocation data, not its p99, with the normal run."
fi
