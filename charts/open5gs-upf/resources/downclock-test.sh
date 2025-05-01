#!/bin/bash

# === Configuration ===

# --- iPerf3 Settings ---
SERVER="$1"
ROUNDS="${2:-1}"  # Default to 1 round if not specified
DURATION=1800     # iperf3 test duration (seconds) - 30 minutes
SLEEP_BETWEEN=10 # Sleep between iperf3 tests (seconds)
IPERF_PORT=5201
LOG_DIR="/mnt/data/iperf3-downclock"
LOG_BASENAME="iperf3_4tests" # Reverted to original base name
UDP_UL_RATE="40M"
UDP_DL_RATE="350M"

# --- CPU Downclocking Settings (Silent Operation) ---
START_FREQ=3500000  # Start frequency in kHz (3.5 GHz)
END_FREQ=1200000    # End frequency in kHz (1.2 GHz)
STEP=50000          # Step size in kHz (50 MHz)
INTERVAL=30         # Seconds between frequency steps
# Options for TARGET_CPUS: "all", ranges "2-5 8", list "0 1 2"
TARGET_CPUS="0 1 2 3 4 5 6 7 8 9 10 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63"
MAX_CPU_INDEX=63 # Adjust if your system has more/less than 64 logical CPUs

# === End Configuration ===

# --- Internal Variables ---
TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
IPERF_LOGFILE="${LOG_DIR}/${LOG_BASENAME}_${TIMESTAMP}.log"
# DOWNCLOCK_PID is no longer global, will be handled locally in run_test
CPU_LIST=()      # Populated by parse_cpu_list
CURRENT_DOWNCLOCK_PID="" # Global variable to track the current downclock PID for cleanup

# === Functions ===

# --- Logging (for iperf3 script events ONLY) ---
log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] $1" | tee -a "$IPERF_LOGFILE"
}

# --- CPU Frequency Control Functions (Silent) ---
parse_cpu_list() {
  local raw="$1"
  local cpus=()
  local i # Declare loop variable locally

  if [[ "$raw" == "all" ]]; then
    for ((i=0; i<=MAX_CPU_INDEX; i++)); do
      cpus+=("$i")
    done
  else
    # Replace commas with spaces for easier processing
    raw="${raw//,/ }"
    for part in $raw; do
      if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start=${BASH_REMATCH[1]}
        local end=${BASH_REMATCH[2]}
        if (( start <= end )); then
           for ((i=start; i<=end; i++)); do
            cpus+=("$i")
           done
        fi
      elif [[ $part =~ ^[0-9]+$ ]]; then
        cpus+=("$part")
      fi
    done
  fi
  # Deduplicate the list
  CPU_LIST=($(printf "%s\n" "${cpus[@]}" | sort -un))
  # No logging about targeted CPUs
}

set_selected_cpus_freq() {
  local freq=$1
  # No logging of frequency changes
  local cpu_id # Declare local variable
  for cpu_id in "${CPU_LIST[@]}"; do
    local freq_file="/sys/devices/system/cpu/cpu$cpu_id/cpufreq/scaling_max_freq"
    # Check if file exists and is writable before attempting to write
    # Silently attempt to set freq
    echo "$freq" > "$freq_file" 2>/dev/null || : # Ignore errors for individual cores if file not writeable
     # Silently check governor (optional but good practice)
     local gov_file="/sys/devices/system/cpu/cpu$cpu_id/cpufreq/scaling_governor"
     if [[ -e $gov_file ]]; then
         local current_gov
         current_gov=$(cat "$gov_file")
         if [[ "$current_gov" != "userspace" && "$current_gov" != "performance" ]]; then
             # If needed, you could attempt to silently set it here:
             # echo "userspace" | sudo tee "$gov_file" > /dev/null 2>&1
             : # Do nothing, just acknowledge the check happened
         fi
     fi
  done
}


# Function to perform ONE downclock cycle (start -> end) and hold at end_freq
# This will run in the background during each iperf3 test.
downclock_once_and_hold() {
    local current_freq=$START_FREQ
    set_selected_cpus_freq "$START_FREQ" # Ensure start freq

    # Loop downwards towards END_FREQ
    while (( current_freq > END_FREQ )); do
        set_selected_cpus_freq "$current_freq"
        sleep "$INTERVAL"

        # Calculate next frequency, ensuring it doesn't go below END_FREQ
        if (( current_freq - STEP <= END_FREQ )); then
            current_freq=$END_FREQ
        else
            (( current_freq -= STEP ))
        fi
    done

    # Ensure the final frequency is exactly END_FREQ
    set_selected_cpus_freq "$END_FREQ"

    # Stay at END_FREQ - sleep indefinitely until killed by the parent process
    while true; do sleep 3600; done
}


# --- iPerf3 Test Function ---
run_test() {
    local description="$1"
    local command="$2"
    local output # Declare local variable
    local local_downclock_pid="" # PID for the downclock process specific to this test

    log "Starting: $description (Duration: ${DURATION}s)"
    log "Command: $command"

    # 1) Start downclocking WHILE iperf3 is running (in the background)
    downclock_once_and_hold &
    local_downclock_pid=$!
    CURRENT_DOWNCLOCK_PID=$local_downclock_pid # Update global PID for cleanup trap
    # No logging for starting downclock process

    # Wait a tiny bit for the downclock process to start and potentially set the first frequency
    sleep 1

    # 2) Run iperf3 and wait for it to finish
    if output=$(eval "$command" 2>&1); then
        # Log SUCCESS to the iperf log file
        echo -e "\n$output\n" >> "$IPERF_LOGFILE" # Append full iperf3 output
        log "Finished: $description - SUCCESS"
    else
        # Log FAILURE to the iperf log file
        log "Finished: $description - FAILURE"
        echo -e "\nError Output:\n$output\n" >> "$IPERF_LOGFILE" # Append error output
    fi

    # 3) ONLY WHEN iperf3 test ends, stop the downclock process and reset CPU freq
    # Silently kill the background downclock process for THIS test
    if [[ -n "$local_downclock_pid" ]] && kill -0 "$local_downclock_pid" 2>/dev/null; then
        kill "$local_downclock_pid"
        wait "$local_downclock_pid" 2>/dev/null # Wait for it to terminate silently
    fi
    CURRENT_DOWNCLOCK_PID="" # Clear the global PID tracker

    # Reset frequency to START_FREQ silently AFTER stopping the downclock process
    set_selected_cpus_freq "$START_FREQ"
    # No logging about frequency reset here

    log "Sleeping for $SLEEP_BETWEEN seconds..."
    sleep "$SLEEP_BETWEEN"
}

# --- Cleanup Function ---
cleanup() {
    log "Cleaning up..." # Log cleanup start

    # Kill the currently running downclock process, if any
    if [[ -n "$CURRENT_DOWNCLOCK_PID" ]] && kill -0 "$CURRENT_DOWNCLOCK_PID" 2>/dev/null; then
        # Silently kill the background process
        kill "$CURRENT_DOWNCLOCK_PID"
        wait "$CURRENT_DOWNCLOCK_PID" 2>/dev/null
        # No logging about stopping the downclock process
    fi
    CURRENT_DOWNCLOCK_PID="" # Clear the PID

    # Reset frequency to START_FREQ silently on exit
    # Ensure CPU_LIST is populated if cleanup runs early
    if [[ ${#CPU_LIST[@]} -eq 0 ]]; then
        parse_cpu_list "$TARGET_CPUS"
    fi
    # Check if CPU_LIST was successfully populated
    if [[ ${#CPU_LIST[@]} -gt 0 ]]; then
         set_selected_cpus_freq "$START_FREQ"
         # No logging about frequency reset
    fi

    log "Killing any remaining iperf3 client processes..."
    pkill -f "iperf3 -c $SERVER"

    log "Finished." # Log cleanup end
    # trap automatically exits with the script's exit code or the signal's exit code
}
# Use EXIT trap along with signal traps to ensure cleanup runs on normal exit too
trap cleanup SIGINT SIGTERM EXIT


# === Main Script ===

# Check for mandatory arguments
if [[ -z "$SERVER" ]]; then
    echo "Usage: $0 <server_ip> [rounds]"
    exit 1
fi

# Ensure log directory exists
mkdir -p "$LOG_DIR" || { echo "Failed to create log directory: $LOG_DIR"; exit 1; }

# Parse the CPU list based on configuration (silently)
parse_cpu_list "$TARGET_CPUS"
if [[ ${#CPU_LIST[@]} -eq 0 ]]; then
    # Use standard echo for critical setup error, not the log function
    echo "Error: No target CPUs found based on TARGET_CPUS='$TARGET_CPUS' and MAX_CPU_INDEX=$MAX_CPU_INDEX. Exiting."
    exit 1
fi

# Perform initial frequency set silently to check permissions
# Save current errexit state, disable it, check command, restore state
initial_errexit_state="$-" # Save flags like 'e'
set +e # Disable exit on error temporarily
set_selected_cpus_freq "$START_FREQ"
set_freq_status=$?
# Restore errexit state if it was set
if [[ "$initial_errexit_state" == *e* ]]; then set -e; fi

if [[ $set_freq_status -ne 0 ]]; then
    # Check if *any* frequency was set successfully, allow partial success
    # This check is tricky without verbose output from set_selected_cpus_freq
    # We'll assume if the command didn't exit non-zero *immediately* (due to permission denied on first core), it's likely okay.
    # A more robust check would involve reading back a frequency, but keeping it simple.
    # Re-evaluating the necessity of this check if set_selected_cpus_freq ignores errors:
    # Let's proceed even if some cores fail, as the user might intend that.
    # We just need to ensure we don't exit prematurely due to permissions on *some* cores.
    # The silent error handling `|| :` in set_selected_cpus_freq should prevent script exit if `set -e` is active.
    : # No exit here, proceed cautiously
    echo "Warning: Potentially failed to set initial CPU frequency for some cores. Check permissions or sysfs paths. Continuing..." >&2 # Warning to stderr
fi
# No logging about successful initial set

# Log script start using the iperf3 logger
log "===== Starting 4-Test iPerf3 Routine (Server: $SERVER) ====="
# No logging here about downclocking details


# --- Begin test loop ---
# The loop now just runs the tests sequentially.
# The run_test function handles the downclocking start/stop for each test.
for round in $(seq 1 "$ROUNDS"); do
    log "--- Round $round of $ROUNDS ---"

    # Test 1: UDP Uplink
    run_test "UDP Uplink (-R, ${UDP_UL_RATE})" \
        "iperf3 -c $SERVER -p $IPERF_PORT -u -b $UDP_UL_RATE -t $DURATION -J -R"

    # Test 2: UDP Downlink
    run_test "UDP Downlink (${UDP_DL_RATE})" \
        "iperf3 -c $SERVER -p $IPERF_PORT -u -b $UDP_DL_RATE -t $DURATION -J"

    # Test 3: TCP Uplink
    run_test "TCP Uplink (-R, BBR)" \
        "iperf3 -c $SERVER -p $IPERF_PORT -t $DURATION -C bbr -J -R"

    # Test 4: TCP Downlink
    run_test "TCP Downlink (BBR)" \
        "iperf3 -c $SERVER -p $IPERF_PORT -t $DURATION -C bbr -J"

    # Frequency reset and sleep are handled within run_test after each test completes.
done

log "===== All tests completed ====="

# No explicit exit 0 needed here, the script will exit normally, triggering the EXIT trap for final cleanup.
# The cleanup function handles the final frequency reset.
