#!/bin/bash

# === Configuration ===

# --- iPerf3 Settings ---
SERVER="$1"
ROUNDS="${2:-1}"  # Default to 1 round if not specified
DURATION=1800     # iperf3 test duration (seconds) - 30 minutes
SLEEP_BETWEEN=10 # Sleep between iperf3 tests (seconds)
IPERF_PORT=5201
LOG_DIR="/mnt/data/iperf3-tests"
LOG_BASENAME="iperf3_4tests"
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

# --- CPU Frequency Control Functions (with stdout debug prints) ---
parse_cpu_list() {
  local raw="$1"
  local cpus=()
  local i

  if [[ "$raw" == "all" ]]; then
    for ((i=0; i<=MAX_CPU_INDEX; i++)); do
      cpus+=("$i")
    done
  else
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
  CPU_LIST=($(printf "%s\n" "${cpus[@]}" | sort -un))
  # Print targeted CPUs to stdout for verification
  echo "[DEBUG Downclock] Targeting CPUs: ${CPU_LIST[*]}"
}

set_selected_cpus_freq() {
  local freq=$1
  local mhz=$((freq / 1000))
  # Print the attempt to stdout
  echo "[DEBUG Downclock $(date '+%T')] Attempting to set scaling_max_freq to ${mhz} MHz (${freq} kHz) for CPUs: ${CPU_LIST[*]}"

  local cpu_id
  local success=0 # Track if any write succeeds
  local attempted=0 # Track if any write was attempted
  for cpu_id in "${CPU_LIST[@]}"; do
    local freq_file="/sys/devices/system/cpu/cpu$cpu_id/cpufreq/scaling_max_freq"
    if [[ -w $freq_file ]]; then
      ((attempted++))
      # Attempt the write, keep output suppressed unless debugging sudo/tee itself
      if echo "$freq" | tee "$freq_file" > /dev/null 2>&1; then
           ((success++))
      else
          echo "[DEBUG Downclock ERROR] Failed to write ${freq} to ${freq_file}" >&2 # Print error to stderr
      fi
    else
       # Print warning to stderr if file isn't writable
       if [[ -e $freq_file ]]; then
           echo "[DEBUG Downclock WARN] Cannot write to ${freq_file} (CPU ${cpu_id}). Check permissions." >&2
       else
           echo "[DEBUG Downclock WARN] File ${freq_file} (CPU ${cpu_id}) does not exist." >&2
       fi
    fi
  done

  # Report outcome to stdout if any attempt was made
  if [[ $attempted -gt 0 ]]; then
      if [[ $success -eq ${#CPU_LIST[@]} ]]; then
          # echo "[DEBUG Downclock $(date '+%T')] Set frequency ${mhz} MHz successfully for all ${#CPU_LIST[@]} targeted CPUs."
          : # Keep output minimal, the "Attempting" message is the key one
      elif [[ $success -gt 0 ]]; then
          echo "[DEBUG Downclock $(date '+%T')] Set frequency ${mhz} MHz for $success / ${#CPU_LIST[@]} targeted CPUs."
      else
          echo "[DEBUG Downclock ERROR $(date '+%T')] Failed to set frequency ${mhz} MHz for any targeted CPU." >&2
      fi
  # else
  #     echo "[DEBUG Downclock $(date '+%T')] No writable scaling_max_freq files found for targeted CPUs."
  fi


  # Check governor silently (optional)
  # ... (governor check code omitted for brevity, can be added back if needed) ...
}

# Function to run the downclocking loop silently in the background
run_downclocking_loop() {
    echo "[DEBUG Downclock $(date '+%T')] Starting background downclocking loop."
    set_selected_cpus_freq "$START_FREQ" # Ensure start freq before loop

    while true; do
      local current_freq=$START_FREQ

      echo "[DEBUG Downclock $(date '+%T')] Starting frequency sweep down from ${START_FREQ} kHz..."
      while (( current_freq >= END_FREQ )); do
        set_selected_cpus_freq "$current_freq"
        sleep "$INTERVAL"
        (( current_freq -= STEP ))
        # Add a check to see if the background process should exit
        # This can prevent loops running after the main script tries to kill it
        # but might add slight overhead. Optional.
        # kill -0 $$ || { echo "[DEBUG Downclock $(date '+%T')] Parent process gone, exiting loop."; exit 0; }
      done

      echo "[DEBUG Downclock $(date '+%T')] Reached END_FREQ (${END_FREQ} kHz). Waiting $INTERVAL sec..."
      sleep "$INTERVAL"

      echo "[DEBUG Downclock $(date '+%T')] Resetting frequency to START_FREQ (${START_FREQ} kHz)."
      set_selected_cpus_freq "$START_FREQ"
      echo "[DEBUG Downclock $(date '+%T')] Starting next cycle wait ($INTERVAL sec)."
      sleep "$INTERVAL" # Wait a bit at the top frequency
    done
}

# --- iPerf3 Test Function ---
run_test() {
    local description="$1"
    local command="$2"
    local output

    log "Starting: $description (Duration: ${DURATION}s)"
    log "Command: $command"

    if output=$(eval "$command" 2>&1); then
        echo -e "\n$output\n" >> "$IPERF_LOGFILE"
        log "Finished: $description - SUCCESS"
    else
        log "Finished: $description - FAILURE"
        echo -e "\nError Output:\n$output\n" >> "$IPERF_LOGFILE"
    fi

    log "Sleeping for $SLEEP_BETWEEN seconds..."
    sleep "$SLEEP_BETWEEN"
}

# --- Cleanup Function ---
cleanup() {
    log "Cleaning up..." # Logged to iperf log

    echo "[DEBUG Downclock $(date '+%T')] Cleanup initiated. Stopping background process..." # To stdout

    if [[ -n "$DOWNCLOCK_PID" ]] && kill -0 "$DOWNCLOCK_PID" 2>/dev/null; then
        kill "$DOWNCLOCK_PID"
        wait "$DOWNCLOCK_PID" 2>/dev/null
        echo "[DEBUG Downclock $(date '+%T')] Background process (PID $DOWNCLOCK_PID) stopped." # To stdout
    else
         echo "[DEBUG Downclock $(date '+%T')] Background process (PID $DOWNCLOCK_PID) not found or already stopped." # To stdout
    fi
    DOWNCLOCK_PID=""

    echo "[DEBUG Downclock $(date '+%T')] Attempting final frequency reset to START_FREQ (${START_FREQ} kHz)." # To stdout
    if [[ ${#CPU_LIST[@]} -eq 0 ]]; then
        # Repopulate if list is empty (e.g., script failed early)
        parse_cpu_list "$TARGET_CPUS"
    fi
    if [[ ${#CPU_LIST[@]} -gt 0 ]]; then
         set_selected_cpus_freq "$START_FREQ"
    else
        echo "[DEBUG Downclock ERROR $(date '+%T')] Cannot reset frequency, CPU list empty." >&2 # To stderr
    fi

    log "Killing any remaining iperf3 client processes..." # Logged to iperf log
    pkill -f "iperf3 -c $SERVER"

    log "Finished." # Logged to iperf log
    echo "[DEBUG Downclock $(date '+%T')] Cleanup finished." # To stdout
    exit 0
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

# Parse the CPU list (will print targeted CPUs to stdout)
parse_cpu_list "$TARGET_CPUS"
if [[ ${#CPU_LIST[@]} -eq 0 ]]; then
    echo "Error: No target CPUs found based on TARGET_CPUS='$TARGET_CPUS' and MAX_CPU_INDEX=$MAX_CPU_INDEX. Exiting." >&2
    exit 1
fi

# Attempt initial frequency set (will print attempt to stdout)
echo "[DEBUG Downclock $(date '+%T')] Performing initial frequency set..."
initial_errexit_state="$-" # Save flags like 'e'
set +e # Disable exit on error temporarily
set_selected_cpus_freq "$START_FREQ"
set_freq_status=$?
if [[ "$initial_errexit_state" == *e* ]]; then set -e; fi

# Check the *result* of the set_selected_cpus_freq call implicitly
# (It prints errors internally now if it fails)
# We mainly care if *sudo* itself failed, less common if permissions are just wrong
if [[ $set_freq_status -ne 0 && $set_freq_status -ne 1 ]]; then # Tee might return 1 on write error, sudo might return something else
    echo "Error: Initial frequency setting failed critically (maybe sudo issue?). Exiting." >&2
    exit 1
fi
echo "[DEBUG Downclock $(date '+%T')] Initial frequency set attempted."


# Log script start using the iperf3 logger
log "===== Starting 4-Test iPerf3 Routine (Server: $SERVER) ====="


# --- Begin test loop ---
for round in $(seq 1 "$ROUNDS"); do
    log "--- Round $round of $ROUNDS ---" # Logged to iperf log

    # Start the downclocking loop in background (will print its start msg to stdout)
    run_downclocking_loop &
    DOWNCLOCK_PID=$!
    echo "[DEBUG Downclock $(date '+%T')] Background downclocking process started (PID: $DOWNCLOCK_PID)." # To stdout

    sleep 2

    # Run the iperf3 tests (logs to iperf log file)
    run_test "UDP Uplink (-R, ${UDP_UL_RATE})" \
        "iperf3 -c $SERVER -p $IPERF_PORT -u -b $UDP_UL_RATE -t $DURATION -J -R"

    run_test "UDP Downlink (${UDP_DL_RATE})" \
        "iperf3 -c $SERVER -p $IPERF_PORT -u -b $UDP_DL_RATE -t $DURATION -J"

    run_test "TCP Uplink (-R, BBR)" \
        "iperf3 -c $SERVER -p $IPERF_PORT -t $DURATION -C bbr -J -R"

    run_test "TCP Downlink (BBR)" \
        "iperf3 -c $SERVER -p $IPERF_PORT -t $DURATION -C bbr -J"

    # Stop the background downclocking process
    echo "[DEBUG Downclock $(date '+%T')] Stopping background process (PID $DOWNCLOCK_PID) for round $round..." # To stdout
    if [[ -n "$DOWNCLOCK_PID" ]] && kill -0 "$DOWNCLOCK_PID" 2>/dev/null; then
        kill "$DOWNCLOCK_PID"
        wait "$DOWNCLOCK_PID" 2>/dev/null
        echo "[DEBUG Downclock $(date '+%T')] Background process stopped." # To stdout
    else
         echo "[DEBUG Downclock $(date '+%T')] Background process (PID $DOWNCLOCK_PID) not found or already stopped." # To stdout
    fi
    DOWNCLOCK_PID=""

    # Reset frequency after stopping the loop (will print attempt to stdout)
    echo "[DEBUG Downclock $(date '+%T')] Resetting frequency after round $round..." # To stdout
    set_selected_cpus_freq "$START_FREQ"

done

log "===== All tests completed =====" # Logged to iperf log

# Cleanup function will be called automatically on normal exit via trap
exit 0
