#!/usr/bin/env bash

# Config
INGRESS_IP="10.38.39.145"      # Replace with your actual Ingress IP/Hostname
HOST_HEADER="snapwall-be.10.38.39.145.sslip.io"     # Virtual host header for Ingress routing
TARGET_URL="https://${INGRESS_IP}/"
CONCURRENCY="${1:-150}"         # Override on the command line, e.g. ./load.sh 150
REQUEST_TIMEOUT=3              # Max seconds per request before curl gives up
CONNECT_TIMEOUT=2              # Max seconds to establish the connection
RPS_WINDOW=5                   # Seconds of history used for the "current" RPS readout

# At this concurrency each worker holds an open socket, and macOS defaults
# to a soft limit of only 256 file descriptors per process (Linux is
# usually 1024+). Raise it for this shell so workers don't start failing
# with "too many open files" once CONCURRENCY climbs. Best-effort: some
# environments cap the hard limit too, so failures here are non-fatal.
DESIRED_ULIMIT=$(( CONCURRENCY * 4 + 256 ))
ulimit -n "$DESIRED_ULIMIT" 2>/dev/null || ulimit -n 4096 2>/dev/null || true

# In-memory channel only: workers write batched counts into this pipe,
# the display loop drains it and keeps totals in shell variables.
# Nothing is ever written to disk — the FIFO's directory entry is
# unlinked immediately after opening, so no file persists at any point.
#
# Note: `mktemp -t` is handled differently by GNU mktemp (Linux) vs BSD
# mktemp (macOS), so we build the template ourselves and skip -t entirely
# — this form is accepted identically by both.
TMP_BASE="${TMPDIR:-/tmp}"
PIPE_PATH=$(mktemp -u "${TMP_BASE%/}/loadgen_pipe.XXXXXX")
mkfifo "$PIPE_PATH"
exec 3<>"$PIPE_PATH"
rm -f "$PIPE_PATH"

echo "🚀 Starting load generator against $TARGET_URL (Host: $HOST_HEADER) with $CONCURRENCY parallel workers..."
echo "Press Ctrl+C at any time to stop."
echo "----------------------------------------------------------------------------------"

pids=()
TOTAL_OK=0
TOTAL_ERR=0

# Cleanup logic on Ctrl+C (SIGINT / SIGTERM)
cleanup() {
    trap - SIGINT SIGTERM

    for pid in "${pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null
    done
    wait 2>/dev/null

    # Final drain: pick up any last counts workers flushed as they died.
    # Workers are already dead (wait returned above), so every line already
    # sitting in the pipe reads back instantly; the loop then blocks for
    # one last second on an empty pipe before timing out and exiting.
    # (Integer-only timeout — bash 3.2 on macOS rejects fractional -t.)
    while read -r -t 1 -u 3 ok err; do
        TOTAL_OK=$((TOTAL_OK + ok))
        TOTAL_ERR=$((TOTAL_ERR + err))
    done

    exec 3>&-  # close the pipe

    echo -e "\r\033[K🛑 Stopping load test..."
    echo "----------------------------------------------------------------------------------"
    echo "📊 Final Summary:"
    echo "   - Successful Requests: $TOTAL_OK"
    echo "   - Failed Requests:     $TOTAL_ERR"
    echo "✅ All workers stopped cleanly."
    exit 0
}

trap cleanup SIGINT SIGTERM

# Worker function — writes small batched "ok err" lines into the shared
# pipe (fd 3, inherited from the parent). Writes below PIPE_BUF (4KB) are
# atomic on Linux, so concurrent workers can't interleave/corrupt a line.
worker() {
    local ok_count=0
    local err_count=0

    flush() {
        if (( ok_count > 0 || err_count > 0 )); then
            echo "$ok_count $err_count" >&3
            ok_count=0
            err_count=0
        fi
    }

    trap 'flush; exit 0' SIGTERM

    while true; do
        status=$(curl -k -s -o /dev/null -w "%{http_code}" \
            --connect-timeout "$CONNECT_TIMEOUT" -m "$REQUEST_TIMEOUT" \
            -H "Host: ${HOST_HEADER}" "$TARGET_URL")

        if [[ "$status" -ge 200 && "$status" -lt 400 ]]; then
            ((ok_count++))
        else
            ((err_count++))
        fi

        # Flush after every request — with 15 workers each already paying a
        # full network round-trip per request, a pipe write is negligible
        # overhead, and batching (the old flush_interval=10) is what caused
        # the display to sit at 0 and then jump by up to 150 at once.
        flush
    done
}

for i in $(seq 1 $CONCURRENCY); do
    worker &
    pids+=($!)
done

# Rolling history for a trailing-window RPS readout (in-memory arrays only)
declare -a hist_t hist_total
start_ts=$(date +%s)
last_print=$start_ts

# `read -t 1` doubles as both drain and pacer: it returns immediately
# whenever a worker has data waiting, or blocks up to 1s when idle.
# We redraw the screen every time new data arrives (so counts climb
# request-by-request, not once a second), and also at least once a
# second even during a lull so the elapsed timer keeps visibly ticking.
# (Integer-only timeout — bash 3.2 on macOS rejects fractional -t.)
while true; do
    got_data=0
    if read -r -t 1 -u 3 ok err; then
        TOTAL_OK=$((TOTAL_OK + ok))
        TOTAL_ERR=$((TOTAL_ERR + err))
        got_data=1
    fi

    now=$(date +%s)
    if (( got_data == 0 )) && (( now - last_print < 1 )); then
        continue
    fi
    last_print=$now

    elapsed=$(( now - start_ts ))
    TOTAL=$((TOTAL_OK + TOTAL_ERR))

    hist_t+=("$now")
    hist_total+=("$TOTAL")

    # Trim history older than the window (keep one extra sample of slack)
    while (( ${#hist_t[@]} > 1 )) && (( now - hist_t[0] > RPS_WINDOW )); do
        hist_t=("${hist_t[@]:1}")
        hist_total=("${hist_total[@]:1}")
    done

    window_dt=$(( now - hist_t[0] ))
    if (( window_dt > 0 )); then
        RPS=$(( (TOTAL - hist_total[0]) / window_dt ))
    else
        RPS=0
    fi

    printf "\r\033[K🔥 Elapsed: %ds | Total: %d (%d req/s, %ds avg) | ✅ Success: %d | ❌ Failed: %d" \
        "$elapsed" "$TOTAL" "$RPS" "$RPS_WINDOW" "$TOTAL_OK" "$TOTAL_ERR"
done