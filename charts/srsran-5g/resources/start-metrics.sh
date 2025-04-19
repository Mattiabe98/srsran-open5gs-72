#!/bin/bash

echo "Starting turbostat monitoring..."

# Output file
LOGFILE="/mnt/data/turbostat_output.txt"

# Interval in seconds
INTERVAL=5

# Start logging loop
while true; do
    # Get current UTC time
    UTC_TIME=$(date -u +"%Y-%m-%d %H:%M:%S")

    # Write timestamp header
    echo "[$UTC_TIME UTC]" >> "$LOGFILE"

    # Run turbostat for one sample
    turbostat --interval "$INTERVAL" >> "$LOGFILE"

    # Optional: separator for readability
    echo "----------------------------------------" >> "$LOGFILE"
done
