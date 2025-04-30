#!/bin/bash

# === Configuration ===

# --- iPerf3 Settings ---
SERVER="$1"
ROUNDS="${2:-1}"  # Default to 1 round if not specified
DURATION=1800     # iperf3 test duration (seconds) - 30 minutes
SLEEP_BETWEEN=10 # Sleep between iperf3 tests (seconds)
IPERF_PORT=5201
LOG_DIR="/mnt/data/iperf3-tests"
LOG_BASENAME="iperf3_4tests" # Reverted to original base name
UDP_UL_RATE="40M"
UDP_DL_RATE="350M"

# --- CPU Downclocking Settings (Silent Operation) ---
START_FREQ=3500000  # Start frequency in kHz (3.5 GHz)
END_FREQ=1200000    # End frequency in kHz (1.2 GHz)
STEP=50000          # Step size in kHz (50 MHz)
INTERVAL=30         # Seconds between frequency steps
# Options for TARGET_CPUS: "all", ranges "2-5 8", list "0 1 2"
TARGET_CPUS="all"
MAX_CPU_INDEX=63 # Adjust if your system has more/less than 64 logical CPUs

# === End Configuration ===

# --- Internal Variables ---
TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
IPERF_LOGFILE="${LOG_DIR}/${LOG_BASENAME}_${TIMESTAMP}.log"
DOWNCLOCK_PID="" # To store the PID of the background downclock process
CPU_LIST=()      # Populated by parse_cpu_list

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
    if [[ -w $freq_file ]]; then
      # Use sudo to write, redirect stdout and stderr to silence it completely
      echo "$freq" | sudo tee "$freq_file" > /dev/null 2>&1
    fi
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

# Function to run the downclocking loop silently in the background
run_downclocking_loop() {
    # No logging about starting
    set_selected_cpus_freq "$START_FREQ" # Ensure start freq before loop

    while true; do
      local current_freq=$START_FREQ

      while (( current_freq >= END_FREQ )); do
        set_selected_cpus_freq "$current_freq"
        sleep "$INTERVAL"
        (( current_freq -= STEP ))
      done

      # Reached bottom, wait before reset
      sleep "$INTERVAL"

      # Reset to start frequency
      set_selected_cpus_freq "$START_FREQ"
      # No logging about reset or cycle start
      sleep "$INTERVAL" # Wait a bit at the top frequency
    done
}

# --- iPerf3 Test Function ---
run_test() {
    local description="$1"
    local command="$2"
    local output # Declare local variable

    log "Starting: $description (Duration: ${DURATION}s)"
    log "Command: $command"

    # Run iperf3 and capture output
    if output=$(eval "$command" 2>&1); then
        # Log SUCCESS to the iperf log file
        echo -e "\n$output\n" >> "$IPERF_LOGFILE" # Append full iperf3 output
        log "Finished: $description - SUCCESS"
    else
        # Log FAILURE to the iperf log file
        log "Finished: $description - FAILURE"
        echo -e "\nError Output:\n$output\n" >> "$IPERF_LOGFILE" # Append error output
    fi

    log "Sleeping for $SLEEP_BETWEEN seconds..."
    sleep "$SLEEP_BETWEEN"
}

# --- Cleanup Function ---
cleanup() {
    log "Cleaning up..." # Log cleanup start

    if [[ -n "$DOWNCLOCK_PID" ]] && kill -0 "$DOWNCLOCK_PID" 2>/dev/null; then
        # Silently kill the background process
        kill "$DOWNCLOCK_PID"
        wait "$DOWNCLOCK_PID" 2>/dev/null
        # No logging about stopping the downclock process
    fi
    DOWNCLOCK_PID="" # Clear the PID regardless

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
    exit 0 # Ensure script exits cleanly after trap
}
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
    echo "Error: Failed to set initial CPU frequency. Check sudo permissions or sysfs paths. Exiting."
    exit 1
fi
# No logging about successful initial set

# Log script start using the iperf3 logger
log "===== Starting 4-Test iPerf3 Routine (Server: $SERVER) ====="
# No logging here about downclocking details


# --- Begin test loop ---
for round in $(seq 1 "$ROUNDS"); do
    log "--- Round $round of $ROUNDS ---"

    # Start the downclocking loop silently in the background
    run_downclocking_loop &
    DOWNCLOCK_PID=$!
    # No logging about starting the background process

    # Wait a moment for the first frequency step to potentially apply
    sleep 2

    # Run the iperf3 tests (these will log using the `log` function)
    run_test "UDP Uplink (-R, ${UDP_UL_RATE})" \
        "iperf3 -c $SERVER -p $IPERF_PORT -u -b $UDP_UL_RATE -t $DURATION -J -R"

    run_test "UDP Downlink (${UDP_DL_RATE})" \
        "iperf3 -c $SERVER -p $IPERF_PORT -u -b $UDP_DL_RATE -t $DURATION -J"

    run_test "TCP Uplink (-R, BBR)" \
        "iperf3 -c $SERVER -p $IPERF_PORT -t $DURATION -C bbr -J -R"

    run_test "TCP Downlink (BBR)" \
        "iperf3 -c $SERVER -p $IPERF_PORT -t $DURATION -C bbr -J"

    # Stop the background downclocking process silently
    if [[ -n "$DOWNCLOCK_PID" ]] && kill -0 "$DOWNCLOCK_PID" 2>/dev/null; then
        kill "$DOWNCLOCK_PID"
        wait "$DOWNCLOCK_PID" 2>/dev/null # Wait for termination silently
    fi
    DOWNCLOCK_PID="" # Clear the PID
    # No logging about stopping the background process

    # Reset frequency silently after stopping the loop
    set_selected_cpus_freq "$START_FREQ"
    # No logging about frequency reset

done

log "===== All tests completed ====="

# Cleanup function will be called automatically on normal exit via trap
exit 0
