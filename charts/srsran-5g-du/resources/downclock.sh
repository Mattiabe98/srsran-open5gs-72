#!/bin/bash

START_FREQ=3500000  # in kHz
END_FREQ=1200000    # in kHz
STEP=50000          # in kHz
INTERVAL=30         # in seconds

current_freq=$START_FREQ

# Function to apply frequency to all logical CPUs
set_all_cpus_freq() {
  local freq=$1
  echo "Setting scaling_max_freq to $((freq / 1000)) MHz..."
  for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
    freq_file="$cpu_path/cpufreq/scaling_max_freq"
    if [[ -f $freq_file ]]; then
      echo $freq | sudo tee "$freq_file" > /dev/null
    fi
  done
}

# Gradually reduce frequency
while (( current_freq >= END_FREQ )); do
  set_all_cpus_freq $current_freq
  (( current_freq -= STEP ))
  sleep $INTERVAL
done

# Wait, then restore original frequency
echo "Reached $((END_FREQ / 1000)) MHz. Waiting $INTERVAL seconds before restoring..."
sleep $INTERVAL
set_all_cpus_freq $START_FREQ
echo "Restored to $((START_FREQ / 1000)) MHz."
