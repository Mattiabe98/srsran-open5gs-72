#!/bin/bash


echo "Starting perf monitoring..."

# Find the PID of the gnb process (replace with exact name if necessary)
GNB_PID=$(pgrep -f "gnb");

if [ -z "$GNB_PID" ]; then
    echo "gnb process not found. Exiting.";
    sleep 10000;
    exit 1;
fi;

# Start perf monitoring attached to the gnb PID in the background
echo "Starting perf monitoring for gnb process (PID: $GNB_PID)..."
perf record -e cycles,instructions,cache-misses -F 1000 -g -p $GNB_PID -o /mnt/data/perf.data &
PERF_PID=$!



echo "Starting turbostat monitoring..."

# Start turbostat in the background (write output to a file)
turbostat --Summary --interval 1 -o /mnt/data/turbostat_output.txt &
TURBOSTAT_PID=$!
