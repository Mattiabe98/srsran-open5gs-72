#!/bin/bash


echo "Starting perf monitoring..."

# Find the PID of the gnb process (replace with exact name if necessary)
GNB_PID=$(pgrep -f "/usr/local/bin/gnb -c /gnb.yml");

if [ -z "$GNB_PID" ]; then
    echo "gnb process not found. Exiting.";
    sleep 100;
    exit 1;
fi;


# # Check if graceful_shutdown argument is passed
# if [ "$1" == "graceful_shutdown" ]; then
#     echo "Gracefully shutting down perf..."
#     PERF_PID=$(cat /mnt/data/perf_pid.txt)
#     kill -TERM $PERF_PID
#     exit 0
# fi

# # Normal startup flow for metrics
# echo "Starting perf monitoring for gnb process (PID: $GNB_PID)..."
# perf stat -I 1000 -p $GNB_PID -o /mnt/data/perf.data &
# PERF_PID=$!

# # Save PERF_PID to a file for later use in preStop hook
# echo $PERF_PID > /mnt/data/perf_pid.txt

# # Wait for the perf process to complete
# wait $PERF_PID


echo "Starting turbostat monitoring..."

# Start turbostat in the background (write output to a file)
turbostat --Summary --interval 1 -o /mnt/data/turbostat_output.txt &
TURBOSTAT_PID=$!
