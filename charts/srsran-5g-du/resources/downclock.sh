#!/bin/bash

START_FREQ=3500000  # in kHz (3.5 GHz)
END_FREQ=1200000    # in kHz (1.2 GHz)
STEP=50000          # in kHz (50 MHz)
INTERVAL=30         # seconds between steps
LOGFILE="downclock_log.txt"

# === CONFIGURE WHICH LOGICAL CPUs TO AFFECT ===
# Options:
# - "all" (affects CPU0 to CPU63)
# - Ranges like "2-5 8 10-11"
# - Specific list like "0 1 2 3"
TARGET_CPUS="all"

# === INTERNAL ===
parse_cpu_list() {
  local raw="$1"
  local cpus=()

  if [[ "$raw" == "all" ]]; then
    for ((i=0; i<64; i++)); do
      cpus+=("$i")
    done
  else
    for part in $raw; do
      if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
        for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do
          cpus+=("$i")
        done
      elif [[ $part =~ ^[0-9]+$ ]]; then
        cpus+=("$part")
      fi
    done
  fi

  echo "${cpus[@]}"
}

CPU_LIST=($(parse_cpu_list "$TARGET_CPUS"))

set_selected_cpus_freq() {
  local freq=$1
  local mhz=$((freq / 1000))
  local timestamp=$(date '+%F %T')
  echo "[$timestamp] Setting scaling_max_freq to ${mhz} MHz for CPUs: ${CPU_LIST[*]}" | tee -a "$LOGFILE"

  for cpu_id in "${CPU_LIST[@]}"; do
    freq_file="/sys/devices/system/cpu/cpu$cpu_id/cpufreq/scaling_max_freq"
    if [[ -f $freq_file ]]; then
      echo $freq | sudo tee "$freq_file" > /dev/null
    fi
  done
}

# Start loop
echo "=== Downclocking script started at $(date) ===" > "$LOGFILE"

while true; do
  current_freq=$START_FREQ

  while (( current_freq >= END_FREQ )); do
    set_selected_cpus_freq $current_freq
    (( current_freq -= STEP ))
    sleep $INTERVAL
  done

  echo "[$(date '+%F %T')] Reached ${END_FREQ/000/} MHz. Waiting $INTERVAL seconds before reset..." | tee -a "$LOGFILE"
  sleep $INTERVAL

  set_selected_cpus_freq $START_FREQ
  echo "[$(date '+%F %T')] Restored to ${START_FREQ/000/} MHz." | tee -a "$LOGFILE"

  echo
  echo "===== Downclocking sweep completed ====="
  echo "Enter [r] to repeat the sweep (e.g., for next test like TCP), or [q] to quit."
  read -rp "Choice [r/q]: " choice

  case "$choice" in
    [Rr]) echo "Restarting sweep...";;
    [Qq]) echo "Exiting."; break;;
    *) echo "Invalid input. Exiting."; break;;
  esac
done
