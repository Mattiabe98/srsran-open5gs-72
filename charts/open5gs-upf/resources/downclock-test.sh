#!/bin/bash

# --- Configuration ---
SERVER="$1"
ROUNDS="$2"

if [ -z "$SERVER" ] || [ -z "$ROUNDS" ]; then
  echo "Usage: $0 <server_ip> <number of rounds>"
  exit 1
fi

IPERF_PORT="5201"
DURATION=60
SLEEP_BETWEEN=7
LOG_DIR="/mnt/data/iperf3-tests"
LOG_BASENAME="iperf3_simple"
FAILURE_COUNT=0

mkdir -p "$LOG_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
LOGFILE="${LOG_DIR}/${LOG_BASENAME}_${TIMESTAMP}.log"

# --- Logging Function ---
log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] $1" | tee -a "$LOGFILE"
}

run_test() {
  local description="$1"
  local cmd="$2"

  log "Starting: $description"
  log "Command: $cmd"
  
  if output=$(eval "$cmd" 2>&1); then
    echo "" >> "$LOGFILE"
    echo "$output" >> "$LOGFILE"
    echo "" >> "$LOGFILE"
    log "Finished: $description - SUCCESS"
  else
    log "Finished: $description - FAILURE"
    echo "$output" | sed 's/^/  /' >> "$LOGFILE"
    ((FAILURE_COUNT++))
  fi

  log "Sleeping for ${SLEEP_BETWEEN}s..."
  sleep "$SLEEP_BETWEEN"
}

cleanup() {
  log "===== Script interrupted or finished ====="
  log "Total failures: $FAILURE_COUNT"
  log "Log file: $LOGFILE"
  pkill -f "iperf3 -c $SERVER"
  sleep 5
  exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# --- Initial Checks ---
log "Checking server availability..."
if ! iperf3 -c "$SERVER" -p "$IPERF_PORT" -t 2 -J > /dev/null 2>&1; then
  log "ERROR: Server not reachable"
  exit 1
fi
log "Server is reachable."

# --- Test Loop ---
for i in $(seq 1 "$ROUNDS"); do
  log "===== Round $i of $ROUNDS ====="
  
  run_test "UDP Uplink (Max 40M)" \
    "iperf3 -c $SERVER -p $IPERF_PORT -u -b 40M -t $DURATION -J -R"

  run_test "UDP Downlink (Max 350M)" \
    "iperf3 -c $SERVER -p $IPERF_PORT -u -b 350M -t $DURATION -J"

  run_test "TCP Uplink (BBR)" \
    "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -J -R"

  run_test "TCP Downlink (BBR)" \
    "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -J"
done
