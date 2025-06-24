#!/bin/bash

# Consider removing 'set -e' if you want the trap/wait logic to always run,
# especially during shutdown signal handling.
# Or keep it if you are sure no setup command should fail silently.
set -x # Keep -x for debugging if needed, remove for production

# --- Your existing setup code remains the same ---
resolve_ip() {
    python3 -c "import socket; print(socket.gethostbyname('$1'))" 2>/dev/null
}

# Resolve addresses
if [[ -n "$AMF_HOSTNAME" ]]; then
    export AMF_ADDR="$(resolve_ip "$AMF_HOSTNAME")"
fi

if [[ -z "${AMF_BIND_ADDR}" ]] ; then
    export AMF_BIND_ADDR=$(hostname -I | awk '{print $1}')
fi

if [[ ! -z "$GNB_HOSTNAME" ]] ; then 
    export GNB_ADDRESS="$(resolve_ip "$GNB_HOSTNAME")"
fi

if [[ ! -z "$UE_HOSTNAME" ]] ; then 
    export UE_ADDRESS="$(resolve_ip "$UE_HOSTNAME")"
fi

export E2_ADDR=$(resolve_ip "$E2_HOSTNAME")

# Generate config
sed -e "s/\${AMF_BIND_ADDR}/$AMF_BIND_ADDR/g" \
    -e "s/\${AMF_ADDR}/$AMF_ADDR/g" \
    -e "s/\${E2_ADDR}/$E2_ADDR/g" \
    < /gnb-template.yml > /gnb.yml

# Disable polling for display driver
echo N | tee /sys/module/drm_kms_helper/parameters/poll >/dev/null

# DPDK device bind
/opt/dpdk/23.11.1/bin/dpdk-devbind.py --bind vfio-pci 0000:51:11.0

# --- Graceful Shutdown Logic ---

# Initialize PIDs
monitoring_pid=0
srsdu_pid=0

# Cleanup function to ensure we try to kill children on exit
cleanup() {
    echo "Running cleanup..."
    if [ $monitoring_pid -ne 0 ]; then
        echo "Sending SIGTERM to monitoring (PID: $monitoring_pid)..."
        kill -TERM "$monitoring_pid" 2>/dev/null || true # Ignore error if already gone
    fi
    if [ $srsdu_pid -ne 0 ]; then
        echo "Sending SIGTERM to srsdu (PID: $srsdu_pid)..."
        kill -TERM "$srsdu_pid" 2>/dev/null || true # Ignore error if already gone
    fi
    # Wait briefly for children to potentially exit after signal
    wait $monitoring_pid $srsdu_pid 2>/dev/null
    echo "Cleanup finished."
}


# Signal handler function
term_handler() {
  echo "Caught SIGTERM/SIGINT signal! Initiating shutdown..."
  # Call cleanup function to signal children
  cleanup
  # Exit the script
  exit 143 # 128 + 15 (SIGTERM)
}

# Trap SIGTERM and SIGINT to call term_handler
trap 'term_handler' TERM INT
# Trap EXIT to call cleanup function on any script exit (normal or error)
trap 'cleanup' EXIT

# Start monitoring in the background
echo "Starting monitoring..."
TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
LOGFILE="/mnt/data/monitoring/monitoring_$TIMESTAMP.txt"
# Run in a subshell to handle redirection easily
(
    # Use exec within the subshell so python3 becomes the process
    # associated with the subshell, making signal handling slightly cleaner.
    exec python3 /monitoring.py -N 1 -c 0-63 >> "$LOGFILE" 2>&1
) &
monitoring_pid=$!
echo "Monitoring started with PID: $monitoring_pid"


# Launch srsDU in the background as well
echo "Starting srsdu..."
stdbuf -oL -eL /usr/local/bin/srsdu -c /gnb.yml &
srsdu_pid=$!
echo "srsdu started with PID: $srsdu_pid"


# Wait for EITHER process to exit. If one exits, we likely want to stop the other.
echo "Waiting for srsdu (PID: $srsdu_pid) or monitoring (PID: $monitoring_pid) to exit..."
wait -n $srsdu_pid $monitoring_pid

# Check which process exited or if wait was interrupted by a signal
exit_code=$?
echo "Wait exited with status: $exit_code"

# If wait exited normally (not due to signal handled by trap),
# figure out which process died and potentially kill the other one.
# The EXIT trap will handle the actual killing on script exit.
if kill -0 $srsdu_pid 2>/dev/null; then
    echo "srsdu (PID: $srsdu_pid) is still running."
else
    echo "srsdu (PID: $srsdu_pid) has exited."
    srsdu_pid=0 # Mark as exited
fi

if kill -0 $monitoring_pid 2>/dev/null; then
    echo "Monitoring (PID: $monitoring_pid) is still running."
else
    echo "Monitoring (PID: $monitoring_pid) has exited."
    monitoring_pid=0 # Mark as exited
fi

# Script will now exit, triggering the 'trap cleanup EXIT'
echo "Script finished waiting, exiting..."

# Let the EXIT trap handle final cleanup and script exit code.
# If terminated by signal, term_handler already called exit.
# If one process exited normally, EXIT trap runs cleanup, and script exits 0.
exit 0
