#!/bin/bash

echo "Starting turbostat monitoring..."

# Output file
LOGFILE="/mnt/data/turbostat_output.txt"

INTERVAL=5

# Start turbostat in the background
turbostat --interval "$INTERVAL" | while IFS= read -r line; do
    # Check if line is the summary line (start of a new measurement block)
    if [[ "$line" =~ ^\ *- ]]; then
        UTC_TIME=$(date -u +"%Y-%m-%d %H:%M:%S")
        echo "[$UTC_TIME UTC]" >> "$LOGFILE"
    fi

    echo "$line" >> "$LOGFILE"
done
