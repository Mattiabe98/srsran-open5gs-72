#!/bin/bash

set -m # IMPORTANT: Enable Job Control for process group management

# --- Configuration ---
SERVERS_CSV="$1"
ROUNDS="$2"

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is not installed. Please install jq to use this script."
    echo "e.g., sudo apt install jq OR sudo yum install jq"
    exit 1
fi

if [ -z "$SERVERS_CSV" ] || [ -z "$ROUNDS" ]; then
  echo "Usage: $0 <server_ip1[:port1],server_ip2[:port2],...> <number of rounds>"
  exit 1
fi

DEFAULT_IPERF_PORT="5201"
LOG_DIR="/mnt/data/iperf3-tests"
MAIN_LOG_BASENAME="iperf3_multi_ue_controller"
SUMMARY_CSV_BASENAME="iperf3_multi_ue_summary"
DURATION=60
BURST_DURATION=10
SLEEP_BETWEEN_TESTS=7
UPLINK_RATES=("5M" "10M" "20M" "30M" "35M")
UPLINK_MAX_ATTEMPT_RATE="40M"
DOWNLINK_RATES=("10M" "50M" "100M" "150M" "200M" "250M" "300M" "350M")
BURSTY_UPLINK_RATE="50M"
BURSTY_DOWNLINK_RATE="300M"
BIDIR_UDP_RATE="30M"
SMALL_PACKET_LEN=200
SMALL_PACKET_RATE="2M"
SMALL_MSS=576
PARALLEL_STREAMS_SUSTAINED=10
PARALLEL_STREAMS_BURST=5
# --- End Configuration ---


# --- Script Setup ---
MAIN_TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
MAIN_LOGFILE="${LOG_DIR}/${MAIN_LOG_BASENAME}_${MAIN_TIMESTAMP}.log"
SUMMARY_CSV_FILE="${LOG_DIR}/${SUMMARY_CSV_BASENAME}_${MAIN_TIMESTAMP}.csv"

declare -A CHILD_PIDS # Stores subshell PIDs (which are also their PGIDs due to set -m)
declare -A UE_LOGFILES
SCRIPT_INTERRUPTED_FLAG=0 # Flag to indicate if SIGINT/SIGTERM was received
CORE_CLEANUP_COMPLETED_FLAG=0 # Flag to ensure core cleanup runs only once

# --- Logging and Summary Functions ---
main_log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [CONTROLLER PID:$$] $1" | tee -a "$MAIN_LOGFILE"
}

append_to_summary() {
    local ue_ip="$1"; local ue_port="$2"; local test_desc="$3"; local cmd_protocol="$4"
    local cmd_direction="$5"; local cmd_rate_target="$6"; local cmd_duration="$7"; local status="$8"
    local avg_mbps="$9"; local total_mb="${10}"; local udp_lost_packets="${11}"
    local udp_lost_percent="${12}"; local udp_jitter_ms="${13}"; local tcp_retransmits="${14}"
    echo "\"$MAIN_TIMESTAMP\",\"$ue_ip\",\"$ue_port\",\"$test_desc\",\"$cmd_protocol\",\"$cmd_direction\",\"$cmd_rate_target\",\"$cmd_duration\",\"$status\",\"$avg_mbps\",\"$total_mb\",\"$udp_lost_packets\",\"$udp_lost_percent\",\"$udp_jitter_ms\",\"$tcp_retransmits\"" >> "$SUMMARY_CSV_FILE"
}

# --- run_test_internal Function ---
run_test_internal() {
    local server_ip=$1; local server_port=$2; local ue_logfile=$3
    local description=$4; local full_command_template=$5
    local full_command=$(echo "$full_command_template" | sed "s/%SERVER%/$server_ip/g" | sed "s/%PORT%/$server_port/g")
    local cmd_protocol="TCP"; if echo "$full_command" | grep -q -- "-u"; then cmd_protocol="UDP"; fi
    local cmd_direction="Downlink"; if echo "$full_command" | grep -q -- "--bidir"; then cmd_direction="Bidir"; elif echo "$full_command" | grep -q -- "-R"; then cmd_direction="Uplink"; fi
    local cmd_rate_target=$(echo "$full_command" | grep -o -- '-b [^ ]*' | cut -d' ' -f2); if [ -z "$cmd_rate_target" ]; then cmd_rate_target="Uncapped"; fi
    local cmd_duration=$(echo "$full_command" | grep -o -- '-t [0-9]\+' | grep -o '[0-9]\+'); if [[ -z "$cmd_duration" ]]; then cmd_duration="?"; fi

    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Starting: $description (Duration: ${cmd_duration}s)" | tee -a "$ue_logfile"
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Command: ${full_command}" | tee -a "$ue_logfile"
    local output; local exit_status
    # iperf3 is run in foreground relative to this function call / command substitution
    if output=$(eval "$full_command" 2>&1); then
        echo "" >> "$ue_logfile"; echo "$output" >> "$ue_logfile"; echo "" >> "$ue_logfile"
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Finished: $description - SUCCESS" | tee -a "$ue_logfile"
        if [[ "$cmd_direction" == "Bidir" ]]; then
            local avg_mbps_ul=$(echo "$output" | jq -r '(.end.sum_sent.bits_per_second // 0) / 1000000'); local total_mb_ul=$(echo "$output" | jq -r '(.end.sum_sent.bytes // 0) / (1024*1024)'); local retrans_ul=$(echo "$output" | jq -r '.end.sum_sent.retransmits // "N/A"')
            append_to_summary "$server_ip" "$server_port" "$description (Uplink part)" "$cmd_protocol" "Bidir-Uplink" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps_ul" "$total_mb_ul" "N/A" "N/A" "N/A" "$retrans_ul"
            local avg_mbps_dl=$(echo "$output" | jq -r '(.end.sum_received.bits_per_second // 0) / 1000000'); local total_mb_dl=$(echo "$output" | jq -r '(.end.sum_received.bytes // 0) / (1024*1024)')
            append_to_summary "$server_ip" "$server_port" "$description (Downlink part)" "$cmd_protocol" "Bidir-Downlink" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps_dl" "$total_mb_dl" "N/A" "N/A" "N/A" "N/A"
        elif [[ "$cmd_protocol" == "TCP" ]]; then
            local avg_mbps; local tcp_retrans; local total_mb
            if [[ "$cmd_direction" == "Uplink" ]]; then avg_mbps=$(echo "$output" | jq -r '(.end.sum_sent.bits_per_second // 0) / 1000000'); total_mb=$(echo "$output" | jq -r '(.end.sum_sent.bytes // 0) / (1024*1024)'); tcp_retrans=$(echo "$output" | jq -r '.end.sum_sent.retransmits // "N/A"')
            else avg_mbps=$(echo "$output" | jq -r '(.end.sum_received.bits_per_second // 0) / 1000000'); total_mb=$(echo "$output" | jq -r '(.end.sum_received.bytes // 0) / (1024*1024)'); tcp_retrans="N/A"; fi
            append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps" "$total_mb" "N/A" "N/A" "N/A" "$tcp_retrans"
        elif [[ "$cmd_protocol" == "UDP" ]]; then
            local avg_mbps=$(echo "$output" | jq -r '(.end.sum.bits_per_second // 0) / 1000000'); local total_mb=$(echo "$output" | jq -r '(.end.sum.bytes // 0) / (1024*1024)')
            local lost_packets=$(echo "$output" | jq -r '.end.sum.lost_packets // "N/A"'); local lost_percent=$(echo "$output" | jq -r '.end.sum.lost_percent // "N/A"'); local jitter_ms=$(echo "$output" | jq -r '.end.sum.jitter_ms // "N/A"')
            append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps" "$total_mb" "$lost_packets" "$lost_percent" "$jitter_ms" "N/A"
        fi; return 0
    else
        exit_status=$?; echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Finished: $description - FAILURE (Exit Code: $exit_status)" | tee -a "$ue_logfile"
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Error Output/Details:" | tee -a "$ue_logfile"; echo "$output" | sed 's/^/  /' >> "$ue_logfile"
        append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "FAILURE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        return 1
    fi
}

# --- Function to run all tests for a SINGLE UE (this will be backgrounded) ---
run_all_tests_for_single_ue() {
    local ue_server_ip=$1; local ue_server_port=$2
    local ue_id_for_log=$(echo "$ue_server_ip" | tr '.' '_')_$(echo "$ue_server_port")
    local ue_timestamp=$(date -u +"%Y-%m-%d_%H-%M-%S"); local ue_logfile="${LOG_DIR}/iperf3_traffic_UE_${ue_id_for_log}_${ue_timestamp}.log"
    UE_LOGFILES["$ue_server_ip:$ue_server_port"]="$ue_logfile"; local failure_count_ue=0
    log_ue() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE_SUBSHELL_PID:$$] [TARGET: $ue_server_ip:$ue_server_port] $1" | tee -a "$ue_logfile"; }
    
    # Subshell's own cleanup trap
    ue_subshell_cleanup() {
        log_ue "SUBSHELL CLEANUP (PID:$$): Signal received. Terminating its iperf3 clients for $ue_server_ip:$ue_server_port."
        # Kill iperf3 processes that are direct children of this subshell
        pkill -KILL -P $$ 2>/dev/null
        # General kill for iperf3 to this specific UE, in case it wasn't a direct child (e.g. due to complex eval)
        pkill -KILL -f "iperf3 -c $ue_server_ip -p $ue_server_port" 2>/dev/null
        log_ue "SUBSHELL CLEANUP (PID:$$): pkill attempts completed."
        # The subshell will exit due to the signal or naturally after this trap.
    }
    trap 'ue_subshell_cleanup; exit 143;' SIGTERM # 128+15 = 143 for SIGTERM
    trap 'ue_subshell_cleanup; exit 130;' SIGINT  # 128+2 = 130 for SIGINT
    # No EXIT trap here, rely on main script's EXIT trap for normal completion logging of subshell.

    log_ue "===== Starting iPerf3 Test Suite for UE: $ue_server_ip:$ue_server_port (PID:$$) ====="; log_ue "Logging to: $ue_logfile"
    if ! iperf3 -c "$ue_server_ip" -p "$ue_server_port" -t 2 -J > /dev/null 2>&1; then
        log_ue "ERROR: iPerf3 server at $ue_server_ip:$ue_server_port is not reachable."; append_to_summary "$ue_server_ip" "$ue_server_port" "Initial Reachability Check" "N/A" "N/A" "N/A" "2s" "FAILURE - UNREACHABLE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"; exit 2
    else log_ue "Server check successful for $ue_server_ip:$ue_server_port."; fi

    for i in $(seq 1 "$ROUNDS"); do
        log_ue "===== Test Round $i of $ROUNDS for UE $ue_server_ip:$ue_server_port ====="
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink (Single Stream, Uncapped)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Downlink (Single Stream, Uncapped)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -J" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink ($PARALLEL_STREAMS_SUSTAINED Parallel, Uncapped)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -P $PARALLEL_STREAMS_SUSTAINED -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Downlink ($PARALLEL_STREAMS_SUSTAINED Parallel, Uncapped)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -P $PARALLEL_STREAMS_SUSTAINED -J" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        for rate in "${UPLINK_RATES[@]}"; do run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink (Rate Limited: $rate)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -b $rate -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"; done
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink (Rate Limited: $UPLINK_MAX_ATTEMPT_RATE)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -b $UPLINK_MAX_ATTEMPT_RATE -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        for rate in "${DOWNLINK_RATES[@]}"; do run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Downlink (Rate Limited: $rate)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -b $rate -J" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"; done
        for rate in "${UPLINK_RATES[@]}"; do run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Uplink (Rate: $rate)" "iperf3 -c %SERVER% -p %PORT% -u -b $rate -t $DURATION -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"; done
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Uplink (Rate: $UPLINK_MAX_ATTEMPT_RATE)" "iperf3 -c %SERVER% -p %PORT% -u -b $UPLINK_MAX_ATTEMPT_RATE -t $DURATION -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        for rate in "${DOWNLINK_RATES[@]}"; do run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Downlink (Rate: $rate)" "iperf3 -c %SERVER% -p %PORT% -u -b $rate -t $DURATION -J" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"; done
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Bidirectional (Uncapped)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION --bidir -J" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Bidirectional (Rate: $BIDIR_UDP_RATE)" "iperf3 -c %SERVER% -p %PORT% -u -b $BIDIR_UDP_RATE -t $DURATION --bidir -J" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Uplink (Small Pkts: ${SMALL_PACKET_LEN}B, Rate: ${SMALL_PACKET_RATE})" "iperf3 -c %SERVER% -p %PORT% -u -b $SMALL_PACKET_RATE -t $DURATION -l $SMALL_PACKET_LEN -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Downlink (Small Pkts: ${SMALL_PACKET_LEN}B, Rate: ${SMALL_PACKET_RATE})" "iperf3 -c %SERVER% -p %PORT% -u -b $SMALL_PACKET_RATE -t $DURATION -l $SMALL_PACKET_LEN -J" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink (Small MSS: ${SMALL_MSS}B, Uncapped)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -M $SMALL_MSS -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Downlink (Small MSS: ${SMALL_MSS}B, Uncapped)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -M $SMALL_MSS -J" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        local low_rate_small_mss=${UPLINK_RATES[1]}; run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink (Small MSS: ${SMALL_MSS}B, Rate: ${low_rate_small_mss})" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -M $SMALL_MSS -b ${low_rate_small_mss} -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Bursty Uplink (${BURSTY_UPLINK_RATE} for ${BURST_DURATION}s)" "iperf3 -c %SERVER% -p %PORT% -u -b $BURSTY_UPLINK_RATE -t $BURST_DURATION -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Bursty Downlink (${BURSTY_DOWNLINK_RATE} for ${BURST_DURATION}s)" "iperf3 -c %SERVER% -p %PORT% -u -b $BURSTY_DOWNLINK_RATE -t $BURST_DURATION -J" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Bursty Uplink ($PARALLEL_STREAMS_BURST parallel, ${BURST_DURATION}s)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $BURST_DURATION -P $PARALLEL_STREAMS_BURST -J -R" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Bursty Downlink ($PARALLEL_STREAMS_BURST parallel, ${BURST_DURATION}s)" "iperf3 -c %SERVER% -p %PORT% -C bbr -t $BURST_DURATION -P $PARALLEL_STREAMS_BURST -J" || ((failure_count_ue++)); sleep "$SLEEP_BETWEEN_TESTS"
        log_ue "===== Finished Round $i for UE $ue_server_ip:$ue_server_port. Failures in round: $failure_count_ue ====="
    done
    log_ue "===== All test rounds completed for UE $ue_server_ip:$ue_server_port ====="; log_ue "Total failures for this UE: $failure_count_ue"; exit "$failure_count_ue"
}

# --- Main Cleanup Routines ---
# Core cleanup function for child processes and iperf3
perform_core_cleanup() {
    if [ "$CORE_CLEANUP_COMPLETED_FLAG" -eq 1 ]; then
        main_log "CORE_CLEANUP: Already performed. Skipping."
        return
    fi
    CORE_CLEANUP_COMPLETED_FLAG=1
    main_log "CORE_CLEANUP: Initiating cleanup of child processes and iperf3 instances..."

    # Terminate child subshells (which are process group leaders)
    for ue_key in "${!CHILD_PIDS[@]}"; do
        local child_pgid="${CHILD_PIDS[$ue_key]}"
        if ps -p "$child_pgid" > /dev/null; then
            main_log "CORE_CLEANUP: Sending SIGTERM to process group -$child_pgid (UE: $ue_key, Subshell PID: $child_pgid)"
            kill -TERM -- "-$child_pgid" 2>/dev/null # Kill entire process group
        fi
    done

    # Short wait for graceful termination
    # This sleep is intentionally short and if interrupted by another Ctrl+C, it's okay, SIGKILL follows.
    # The main interrupt trap (handle_main_interrupt) should prevent re-entry issues.
    main_log "CORE_CLEANUP: Waiting up to 3s for children to terminate..."
    sleep 3

    # Forcefully kill any remaining child subshells and their iperf3 clients
    for ue_key in "${!CHILD_PIDS[@]}"; do
        local child_pgid="${CHILD_PIDS[$ue_key]}"
        if ps -p "$child_pgid" > /dev/null; then
            main_log "CORE_CLEANUP: Subshell PGID -$child_pgid (UE: $ue_key) still running. Sending SIGKILL."
            kill -KILL -- "-$child_pgid" 2>/dev/null
        fi
        # Fallback: Explicitly pkill iperf3 related to this UE, in case subshell trap failed or iperf3 detached
        local server_ip_cleanup=${ue_key%%:*}; local server_port_cleanup=${ue_key##*:}
        if [[ "$server_port_cleanup" == "$server_ip_cleanup" ]]; then server_port_cleanup=$DEFAULT_IPERF_PORT; fi
        main_log "CORE_CLEANUP: (Fallback) Force pkill for iperf3 clients to $server_ip_cleanup:$server_port_cleanup"
        pkill -KILL -f "iperf3 -c $server_ip_cleanup -p $server_port_cleanup" 2>/dev/null
    done
    
    # Final general pkill for any other iperf3 client that might have escaped
    main_log "CORE_CLEANUP: (General Fallback) Final pkill for any remaining iperf3 clients to configured servers..."
    local temp_servers_array_cleanup; IFS=',' read -ra temp_servers_array_cleanup <<< "$SERVERS_CSV"
    for server_entry_cleanup in "${temp_servers_array_cleanup[@]}"; do
        local server_ip_general_cleanup=${server_entry_cleanup%%:*}
        pkill -KILL -f "iperf3 -c $server_ip_general_cleanup" 2>/dev/null
    done
    main_log "CORE_CLEANUP: Finished. Logs: Main: $MAIN_LOGFILE, Summary: $SUMMARY_CSV_FILE"
}

# Trap for SIGINT (Ctrl+C) and SIGTERM
handle_main_interrupt() {
    # Check if already handling an interrupt to prevent re-entry from rapid Ctrl+C
    if [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ] && [ "$CORE_CLEANUP_COMPLETED_FLAG" -eq 1 ]; then
        main_log "INTERRUPT_HANDLER: Already interrupted and cleanup completed. Force exiting."
        exit 130 # Or another distinct code if needed
    elif [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ]; then
        main_log "INTERRUPT_HANDLER: Interrupt signal received while already processing an interrupt. Ignoring."
        return
    fi

    SCRIPT_INTERRUPTED_FLAG=1
    main_log "INTERRUPT_HANDLER: SIGINT/SIGTERM received. Cleaning up immediately..."
    
    # Disable further SIGINT/SIGTERM traps for this handler to avoid re-entry during its execution
    trap -- SIGINT SIGTERM
    
    perform_core_cleanup # Perform the actual cleanup of children and iperf3
    
    main_log "INTERRUPT_HANDLER: Cleanup complete. Exiting script now with status 130."
    exit 130 # Crucial: exit immediately after cleanup for interrupt
}
trap 'handle_main_interrupt' SIGINT SIGTERM

# Trap for script EXIT (normal completion, error, or after SIGINT/SIGTERM's exit)
handle_main_exit() {
    local final_exit_status=$? # Get the exit status that caused this trap
    
    # If script was interrupted, handle_main_interrupt should have run and called exit.
    # This EXIT trap will run AFTER handle_main_interrupt's exit.
    if [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ]; then
        main_log "EXIT_HANDLER: Script was interrupted. Cleanup performed by interrupt handler. Final status: $final_exit_status."
        # perform_core_cleanup should have already been called and CORE_CLEANUP_COMPLETED_FLAG set.
        # So, no need to call it again.
        # The 5-minute sleep is definitely skipped.
    else
        # This is for normal script completion or an error exit not from SIGINT/SIGTERM
        main_log "EXIT_HANDLER: Script exiting (Status: $final_exit_status). Performing final cleanup if needed."
        perform_core_cleanup # This will run if not already done (e.g., normal script end)

        if [ "$final_exit_status" -eq 0 ]; then
            main_log "EXIT_HANDLER: Script completed successfully. Sleeping 5 minutes for idle metrics..."
            # This sleep can be interrupted. If Ctrl+C is hit here,
            # because SIGINT trap is reset by `exit 130` in handle_main_interrupt,
            # a new SIGINT would try to run handle_main_interrupt again.
            # To make this sleep truly uninterruptible by a new Ctrl+C:
            (trap '' SIGINT; sleep 300; trap 'handle_main_interrupt' SIGINT)&
            local sleep_pid=$!
            wait "$sleep_pid" || main_log "EXIT_HANDLER: Idle sleep interrupted."
        else
            main_log "EXIT_HANDLER: Script completed with errors (Status: $final_exit_status). Skipping idle sleep."
        fi
    fi
    main_log "EXIT_HANDLER: Script fully finished."
    # The script will exit with the $final_exit_status
}
trap 'handle_main_exit' EXIT


# --- Main Script Logic ---
mkdir -p "$LOG_DIR"; if [ ! -d "$LOG_DIR" ]; then echo "[ERROR] Log dir '$LOG_DIR' failed." >&2; exit 1; fi
echo "\"RunTimestamp\",\"UE_IP\",\"UE_Port\",\"Test_Description\",\"Cmd_Protocol\",\"Cmd_Direction\",\"Cmd_Rate_Target_Mbps\",\"Cmd_Duration_s\",\"Status\",\"Avg_Mbps\",\"Total_MB_Transferred\",\"UDP_Lost_Packets\",\"UDP_Lost_Percent\",\"UDP_Jitter_ms\",\"TCP_Retransmits\"" > "$SUMMARY_CSV_FILE"

main_log "===== Starting Multi-UE iPerf3 Traffic Simulation (PID: $$) ====="
main_log "Target Servers: $SERVERS_CSV"; main_log "Rounds per UE: $ROUNDS"
main_log "Main log: $MAIN_LOGFILE"; main_log "Summary CSV: $SUMMARY_CSV_FILE"

IFS=',' read -ra SERVERS_ARRAY <<< "$SERVERS_CSV"
ALL_UES_REACHABLE=true; main_log "Performing initial reachability checks..."
for server_entry in "${SERVERS_ARRAY[@]}"; do
    server_ip=${server_entry%%:*}; server_port=${server_entry##*:}
    if [[ "$server_port" == "$server_ip" ]]; then server_port=$DEFAULT_IPERF_PORT; fi
    main_log "Checking UE: $server_ip:$server_port..."
    if ! iperf3 -c "$server_ip" -p "$server_port" -t 2 -J > /dev/null 2>&1; then
        main_log "ERROR: UE $server_ip:$server_port not reachable."
        append_to_summary "$server_ip" "$server_port" "Pre-Run Reachability Check" "N/A" "N/A" "N/A" "2s" "FAILURE - UNREACHABLE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        ALL_UES_REACHABLE=false
    else main_log "UE $server_ip:$server_port is reachable."; fi
done
if ! $ALL_UES_REACHABLE; then main_log "One or more UEs not reachable. Exiting."; exit 1; fi
main_log "All specified UEs reachable. Proceeding."

for server_entry in "${SERVERS_ARRAY[@]}"; do
    server_ip=${server_entry%%:*}; server_port=${server_entry##*:}
    if [[ "$server_port" == "$server_ip" ]]; then server_port=$DEFAULT_IPERF_PORT; fi
    main_log "Launching test suite for UE: $server_ip:$server_port in background."
    (run_all_tests_for_single_ue "$server_ip" "$server_port") &
    CHILD_PIDS["$server_ip:$server_port"]=$! 
    main_log "UE $server_ip:$server_port suite started with subshell PID ${CHILD_PIDS["$server_ip:$server_port"]}"
done

OVERALL_SCRIPT_FAILURE=0; TOTAL_TEST_FAILURES_ACROSS_UES=0
main_log "All UE test suites launched. Waiting for completion..."
for ue_key in "${!CHILD_PIDS[@]}"; do
    pid=${CHILD_PIDS[$ue_key]}; wait "$pid"; status=$?
    ue_log_file_path=${UE_LOGFILES[$ue_key]:-"N/A"}
    if [ "$status" -eq 0 ]; then main_log "UE $ue_key (PID $pid) completed successfully. Log: $ue_log_file_path"
    elif [ "$status" -eq 2 ]; then main_log "UE $ue_key (PID $pid) FAILED: Server unreachable. Log: $ue_log_file_path"; OVERALL_SCRIPT_FAILURE=1; TOTAL_TEST_FAILURES_ACROSS_UES=$((TOTAL_TEST_FAILURES_ACROSS_UES + 1))
    else main_log "UE $ue_key (PID $pid) completed with $status failures. Log: $ue_log_file_path"; OVERALL_SCRIPT_FAILURE=1; TOTAL_TET_FAILURES_ACROSS_UES=$((TOTAL_TEST_FAILURES_ACROSS_UES + status)); fi
done

main_log "===== All concurrent UE test suites have finished ====="
if [ "$OVERALL_SCRIPT_FAILURE" -ne 0 ]; then main_log "ERRORS reported. Total individual test failures: $TOTAL_TEST_FAILURES_ACROSS_UES"
else main_log "All UEs completed all tests successfully."; fi

# The EXIT trap (handle_main_exit) will run automatically now.
# Script will exit with OVERALL_SCRIPT_FAILURE status.
exit "$OVERALL_SCRIPT_FAILURE"
