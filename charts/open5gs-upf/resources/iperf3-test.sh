#!/bin/bash

# --- Configuration ---
SERVER="$1"
ROUNDS="$2"

if [ -z "$SERVER" ]; then
  echo "Usage: $0 <server_ip> <number of rounds>"
  exit 1
fi

if [ -z "$ROUNDS" ]; then
  echo "Usage: $0 <server_ip> <number of rounds>"
  exit 1
fi

echo "Using server IP: $SERVER"
IPERF_PORT="5201" # Default iPerf3 port

LOG_DIR="/mnt/data/iperf3-tests" # Ensure this directory exists
LOG_BASENAME="iperf3_traffic"

DURATION=60
BURST_DURATION=10
SLEEP_BETWEEN=7


UPLINK_RATES=("5M" "10M" "20M" "30M" "35M")
UPLINK_MAX_ATTEMPT_RATE="40M"
DOWNLINK_RATES=("10M" "50M" "100M" "150M" "200M" "250M" "300M" "350M")
BURSTY_UPLINK_RATE="50M"
BURSTY_DOWNLINK_RATE="300M"
BIDIR_UDP_RATE="30M"

SMALL_PACKET_LEN=200
SMALL_PACKET_RATE="2M"
SMALL_MSS=576

PARALLEL_STREAMS_SUSTAINED=10
PARALLEL_STREAMS_BURST=5
# --- End Configuration ---


# --- Script Setup ---
TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
LOGFILE="${LOG_DIR}/${LOG_BASENAME}_${TIMESTAMP}.log"
FAILURE_COUNT=0

# Function for logging
log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] $1" | tee -a "$LOGFILE"
}

# --- Revised run_test Function ---
# Accepts only description and the FULL command string
run_test() {
    local description=$1
    local full_command=$2 # Expect the complete iperf3 command WITH -J

    # Try to extract duration from command string for logging (best effort)
    local logged_duration=$(echo "$full_command" | grep -o -- '-t [0-9]\+' | grep -o '[0-9]\+')
    if [[ -z "$logged_duration" ]]; then logged_duration="?"; fi # Handle case where -t not found

    log "Starting: $description (Duration: ${logged_duration}s)"
    log "Command: ${full_command}" # Log the exact command being run

    # Use eval on the full command passed as $2
    if output=$(eval "$full_command" 2>&1); then
        # Success: Append JSON output to log
        # Add a newline before appending JSON for better readability if needed
        echo "" >> "$LOGFILE"
        echo "$output" >> "$LOGFILE"
        echo "" >> "$LOGFILE"
        log "Finished: $description - SUCCESS"
    else
        # Failure: Log error details
        local exit_status=$?
        log "Finished: $description - FAILURE (Exit Code: $exit_status)"
        # Error output might already be in JSON format from iperf3
        log "Error Output/Details:"
        # Indent error output slightly in log
        echo "$output" | sed 's/^/  /' >> "$LOGFILE"
        ((FAILURE_COUNT++))
    fi
    log "Sleeping for ${SLEEP_BETWEEN}s..."
    sleep "$SLEEP_BETWEEN"
}


# Function for cleanup on script exit/interrupt
cleanup() {
    log "===== Script interrupted or finished ====="
    log "Total test failures detected: $FAILURE_COUNT"
    log "Log file: $LOGFILE"
    # Attempt to kill any remaining iperf3 client processes from this script
    # Be cautious if other iperf3 processes might be running
    log "Attempting to clean up any stray iperf3 client processes..."
    pkill -f "iperf3 -c $SERVER"
    log "Sleeping for 5 minutes to record idle metrics..."
    sleep 300
    log "Finished."
    exit 0
}

# --- Main Script Logic ---

# Setup trap for graceful exit
trap cleanup SIGINT SIGTERM EXIT

# Ensure log directory exists
mkdir -p "$LOG_DIR"
if [ ! -d "$LOG_DIR" ]; then
    echo "[ERROR] Log directory '$LOG_DIR' could not be created. Exiting." >&2
    exit 1
fi

# Initial Log Messages (trimmed for brevity)
echo "===== Starting iPerf3 Traffic Simulation (Target: $SERVER:$IPERF_PORT) =====" | tee -a "$LOGFILE"
echo "Logging to: $LOGFILE (using JSON format)" | tee -a "$LOGFILE"
log "Config: DURATION=$DURATION, BURST_DURATION=$BURST_DURATION, SLEEP_BETWEEN=$SLEEP_BETWEEN, ROUNDS=$ROUNDS ..."
log "============================================================="

# Initial Server Reachability Check
log "Performing initial server check..."
# Use the specific port and short duration for the check
if ! iperf3 -c "$SERVER" -p "$IPERF_PORT" -t 2 -J > /dev/null 2>&1; then
    log "ERROR: iPerf3 server at $SERVER:$IPERF_PORT is not reachable or doesn't respond correctly."
    log "Please ensure the iPerf3 server is running ('iperf3 -s') on the target."
    exit 1
else
    log "Server check successful."
fi


# --- Test Execution Loop ---
for i in $(seq 1 $ROUNDS); do
    log "===== Test Round $i of $ROUNDS ====="

    # --- Section 1: Standard TCP (Unconstrained Rate) ---
    log "--- Testing Unconstrained TCP ---"
    # Pass the COMPLETE command string, including -J, as the second argument
    run_test "TCP Uplink (Single Stream, Uncapped)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -J -R"
    run_test "TCP Downlink (Single Stream, Uncapped)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -J"
    run_test "TCP Uplink ($PARALLEL_STREAMS_SUSTAINED Parallel, Uncapped)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -P $PARALLEL_STREAMS_SUSTAINED -J -R"
    run_test "TCP Downlink ($PARALLEL_STREAMS_SUSTAINED Parallel, Uncapped)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -P $PARALLEL_STREAMS_SUSTAINED -J"

    # --- Section 2: Rate-Limited TCP ---
    log "--- Testing Rate-Limited TCP ---"
    for rate in "${UPLINK_RATES[@]}"; do
        run_test "TCP Uplink (Rate Limited: $rate)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -b $rate -J -R"
    done
    run_test "TCP Uplink (Rate Limited: $UPLINK_MAX_ATTEMPT_RATE - Expecting Cap)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -b $UPLINK_MAX_ATTEMPT_RATE -J -R"
    for rate in "${DOWNLINK_RATES[@]}"; do
         run_test "TCP Downlink (Rate Limited: $rate)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -b $rate -J"
    done

    # --- Section 3: Standard UDP ---
    log "--- Testing Standard UDP ---"
    for rate in "${UPLINK_RATES[@]}"; do
        run_test "UDP Uplink (Rate: $rate)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -u -b $rate -t $DURATION -J -R"
    done
    run_test "UDP Uplink (Rate: $UPLINK_MAX_ATTEMPT_RATE - Expecting Loss/Cap)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -u -b $UPLINK_MAX_ATTEMPT_RATE -t $DURATION -J -R"
    for rate in "${DOWNLINK_RATES[@]}"; do
        run_test "UDP Downlink (Rate: $rate)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -u -b $rate -t $DURATION -J"
    done

    # --- Section 4: Bidirectional Tests ---
    log "--- Testing Bidirectional Traffic ---"
    run_test "TCP Bidirectional (Uncapped)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION --bidir -J"
    run_test "UDP Bidirectional (Rate: $BIDIR_UDP_RATE)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -u -b $BIDIR_UDP_RATE -t $DURATION --bidir -J"

    # --- Section 5: Small Packet / High Packet Rate Tests ---
    log "--- Testing Small Packet / High Packet Rate ---"
    run_test "UDP Uplink (Small Packets: ${SMALL_PACKET_LEN}B, Rate: ${SMALL_PACKET_RATE})" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -u -b $SMALL_PACKET_RATE -t $DURATION -l $SMALL_PACKET_LEN -J -R"
    run_test "UDP Downlink (Small Packets: ${SMALL_PACKET_LEN}B, Rate: ${SMALL_PACKET_RATE})" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -u -b $SMALL_PACKET_RATE -t $DURATION -l $SMALL_PACKET_LEN -J"
    run_test "TCP Uplink (Small MSS: ${SMALL_MSS}B, Uncapped)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -M $SMALL_MSS -J -R"
    run_test "TCP Downlink (Small MSS: ${SMALL_MSS}B, Uncapped)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -M $SMALL_MSS -J"
    low_rate_small_mss=${UPLINK_RATES[1]} # Example: use the 10M rate
    run_test "TCP Uplink (Small MSS: ${SMALL_MSS}B, Rate: ${low_rate_small_mss})" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $DURATION -M $SMALL_MSS -b ${low_rate_small_mss} -J -R"

    # --- Section 6: Bursty Traffic ---
    log "--- Testing Bursty Traffic ---"
    run_test "UDP Bursty Uplink (${BURSTY_UPLINK_RATE} for ${BURST_DURATION}s)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -u -b $BURSTY_UPLINK_RATE -t $BURST_DURATION -J -R"
    run_test "UDP Bursty Downlink (${BURSTY_DOWNLINK_RATE} for ${BURST_DURATION}s)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -u -b $BURSTY_DOWNLINK_RATE -t $BURST_DURATION -J"
    run_test "TCP Bursty Uplink ($PARALLEL_STREAMS_BURST parallel, ${BURST_DURATION}s)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $BURST_DURATION -P $PARALLEL_STREAMS_BURST -J -R"
    run_test "TCP Bursty Downlink ($PARALLEL_STREAMS_BURST parallel, ${BURST_DURATION}s)" "iperf3 -c $SERVER -p $IPERF_PORT -C bbr -t $BURST_DURATION -P $PARALLEL_STREAMS_BURST -J"

    log "===== Finished Round $i ====="

done

# Normal completion handled by EXIT trap
