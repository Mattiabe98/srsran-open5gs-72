#!/bin/bash

# VERY FIRST EXECUTABLE LINE for debugging proliferation:
echo "[$(date)] Script instance $$ starting with args: $@" >> /tmp/iperf3_test_script_starts.log

set -m # IMPORTANT: Enable Job Control for process group management

# --- Configuration ---
SERVERS_CSV="$1"
ROUNDS="$2"

# ... (rest of your configuration section remains the same) ...
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is not installed. Please install jq to use this script."
    echo "e.g., sudo apt install jq OR sudo yum install jq"
    exit 1
fi

if [ -z "$SERVERS_CSV" ]; then
  echo "Usage: $0 <server_ip1[:port1],server_ip2[:port2],...> <number of rounds>"
  exit 1
fi

if [ -z "$ROUNDS" ]; then
  echo "Usage: $0 <server_ip1[:port1],server_ip2[:port2],...> <number of rounds>"
  exit 1
fi

DEFAULT_IPERF_PORT="5201"

LOG_DIR="/mnt/data/downclock-test-multi-ue" # Ensure this directory exists
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

declare -A CHILD_PIDS
declare -A UE_LOGFILES
CLEANUP_IN_PROGRESS=0 # Global flag for cleanup re-entrancy

# Function for main script logging
main_log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [CONTROLLER PID:$$] $1" | tee -a "$MAIN_LOGFILE"
}

# Function to write to summary CSV (append_to_summary)
# ... (append_to_summary function remains the same as your last version)
append_to_summary() {
    local ue_ip="$1"; local ue_port="$2"; local test_desc="$3"; local cmd_protocol="$4"
    local cmd_direction="$5"; local cmd_rate_target="$6"; local cmd_duration="$7"; local status="$8"
    local avg_mbps="$9"; local total_mb="${10}"; local udp_lost_packets="${11}"
    local udp_lost_percent="${12}"; local udp_jitter_ms="${13}"; local tcp_retransmits="${14}"
    echo "\"$MAIN_TIMESTAMP\",\"$ue_ip\",\"$ue_port\",\"$test_desc\",\"$cmd_protocol\",\"$cmd_direction\",\"$cmd_rate_target\",\"$cmd_duration\",\"$status\",\"$avg_mbps\",\"$total_mb\",\"$udp_lost_packets\",\"$udp_lost_percent\",\"$udp_jitter_ms\",\"$tcp_retransmits\"" >> "$SUMMARY_CSV_FILE"
}


# --- run_test_internal Function ---
# ... (run_test_internal function remains the same as your last version, parsing JSON with jq)
run_test_internal() {
    local server_ip=$1; local server_port=$2; local ue_logfile=$3
    local description=$4; local full_command_template=$5

    local full_command=$(echo "$full_command_template" | \
                         sed "s/%SERVER%/$server_ip/g" | \
                         sed "s/%PORT%/$server_port/g")

    local cmd_protocol="TCP"; if echo "$full_command" | grep -q -- "-u"; then cmd_protocol="UDP"; fi
    local cmd_direction="Downlink"; if echo "$full_command" | grep -q -- "--bidir"; then cmd_direction="Bidir"; elif echo "$full_command" | grep -q -- "-R"; then cmd_direction="Uplink"; fi
    local cmd_rate_target=$(echo "$full_command" | grep -o -- '-b [^ ]*' | cut -d' ' -f2); if [ -z "$cmd_rate_target" ]; then cmd_rate_target="Uncapped"; fi
    local cmd_duration=$(echo "$full_command" | grep -o -- '-t [0-9]\+' | grep -o '[0-9]\+'); if [[ -z "$cmd_duration" ]]; then cmd_duration="?"; fi

    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Starting: $description (Duration: ${cmd_duration}s)" | tee -a "$ue_logfile"
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Command: ${full_command}" | tee -a "$ue_logfile"

    local output; local exit_status
    # Crucially, iperf3 is run in the foreground relative to the command substitution
    if output=$(eval "$full_command" 2>&1); then
        echo "" >> "$ue_logfile"; echo "$output" >> "$ue_logfile"; echo "" >> "$ue_logfile"
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Finished: $description - SUCCESS" | tee -a "$ue_logfile"
        # ... (jq parsing logic remains the same)
        if [[ "$cmd_direction" == "Bidir" ]]; then
            local avg_mbps_ul=$(echo "$output" | jq -r '(.end.sum_sent.bits_per_second // 0) / 1000000')
            local total_mb_ul=$(echo "$output" | jq -r '(.end.sum_sent.bytes // 0) / (1024*1024)')
            local retrans_ul=$(echo "$output" | jq -r '.end.sum_sent.retransmits // "N/A"')
            append_to_summary "$server_ip" "$server_port" "$description (Uplink part)" "$cmd_protocol" "Bidir-Uplink" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps_ul" "$total_mb_ul" "N/A" "N/A" "N/A" "$retrans_ul"
            local avg_mbps_dl=$(echo "$output" | jq -r '(.end.sum_received.bits_per_second // 0) / 1000000')
            local total_mb_dl=$(echo "$output" | jq -r '(.end.sum_received.bytes // 0) / (1024*1024)')
            append_to_summary "$server_ip" "$server_port" "$description (Downlink part)" "$cmd_protocol" "Bidir-Downlink" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps_dl" "$total_mb_dl" "N/A" "N/A" "N/A" "N/A"
        elif [[ "$cmd_protocol" == "TCP" ]]; then
            local avg_mbps; local tcp_retrans; local total_mb
            if [[ "$cmd_direction" == "Uplink" ]]; then
                avg_mbps=$(echo "$output" | jq -r '(.end.sum_sent.bits_per_second // 0) / 1000000')
                total_mb=$(echo "$output" | jq -r '(.end.sum_sent.bytes // 0) / (1024*1024)')
                tcp_retrans=$(echo "$output" | jq -r '.end.sum_sent.retransmits // "N/A"')
            else
                avg_mbps=$(echo "$output" | jq -r '(.end.sum_received.bits_per_second // 0) / 1000000')
                total_mb=$(echo "$output" | jq -r '(.end.sum_received.bytes // 0) / (1024*1024)')
                tcp_retrans="N/A"
            fi
            append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps" "$total_mb" "N/A" "N/A" "N/A" "$tcp_retrans"
        elif [[ "$cmd_protocol" == "UDP" ]]; then
            local avg_mbps=$(echo "$output" | jq -r '(.end.sum.bits_per_second // 0) / 1000000')
            local total_mb=$(echo "$output" | jq -r '(.end.sum.bytes // 0) / (1024*1024)')
            local lost_packets=$(echo "$output" | jq -r '.end.sum.lost_packets // "N/A"')
            local lost_percent=$(echo "$output" | jq -r '.end.sum.lost_percent // "N/A"')
            local jitter_ms=$(echo "$output" | jq -r '.end.sum.jitter_ms // "N/A"')
            append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps" "$total_mb" "$lost_packets" "$lost_percent" "$jitter_ms" "N/A"
        fi
        return 0
    else
        exit_status=$?
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Finished: $description - FAILURE (Exit Code: $exit_status)" | tee -a "$ue_logfile"
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Error Output/Details:" | tee -a "$ue_logfile"; echo "$output" | sed 's/^/  /' >> "$ue_logfile"
        append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "FAILURE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        return 1
    fi
}

# --- Function to run all tests for a SINGLE UE (this will be backgrounded) ---
run_all_tests_for_single_ue() {
    local ue_server_ip=$1
    local ue_server_port=$2
    local ue_id_for_log=$(echo "$ue_server_ip" | tr '.' '_')_$(echo "$ue_server_port")

    local ue_timestamp=$(date -u +"%Y-%m-%d_%H-%M-%S")
    local ue_logfile="${LOG_DIR}/iperf3_traffic_UE_${ue_id_for_log}_${ue_timestamp}.log"
    UE_LOGFILES["$ue_server_ip:$ue_server_port"]="$ue_logfile" 

    local failure_count_ue=0

    log_ue() { # Log to this UE's specific log file
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE_SUBSHELL_PID:$$] [TARGET: $ue_server_ip:$ue_server_port] $1" | tee -a "$ue_logfile"
    }

    # This trap is for the subshell running run_all_tests_for_single_ue
    cleanup_ue_subshell_and_processes() {
        log_ue "SUBSHELL CLEANUP: Signal received. Terminating iperf3 clients for $ue_server_ip:$ue_server_port."
        # This pkill is crucial. It targets iperf3 commands launched by *this* subshell for *this* UE.
        # -KILL ensures they die. The -f makes the pattern matching more robust.
        pkill -KILL -f "iperf3 -c $ue_server_ip -p $ue_server_port"
        log_ue "SUBSHELL CLEANUP: pkill attempt for iperf3 to $ue_server_ip:$ue_server_port completed."
        # The subshell itself will exit due to the signal or by completing this trap.
    }
    # Trap SIGINT/SIGTERM to clean up iperf3, then EXIT to ensure subshell terminates.
    # The main script's EXIT trap should not rely on this subshell's EXIT trap for iperf3 cleanup,
    # but this provides an important layer.
    trap 'cleanup_ue_subshell_and_processes; exit 1;' SIGINT SIGTERM EXIT


    log_ue "===== Starting iPerf3 Test Suite for UE: $ue_server_ip:$ue_server_port ====="
    # ... (rest of run_all_tests_for_single_ue, including test calls and sleeps, remains the same)
    log_ue "Logging to: $ue_logfile (using JSON format)"
    log_ue "Config: DURATION=$DURATION, BURST_DURATION=$BURST_DURATION, SLEEP_BETWEEN_TESTS=$SLEEP_BETWEEN_TESTS, ROUNDS=$ROUNDS ..."
    log_ue "============================================================="

    log_ue "Performing initial server check for $ue_server_ip:$ue_server_port..."
    if ! iperf3 -c "$ue_server_ip" -p "$ue_server_port" -t 2 -J > /dev/null 2>&1; then
        log_ue "ERROR: iPerf3 server at $ue_server_ip:$ue_server_port is not reachable or doesn't respond correctly."
        append_to_summary "$ue_server_ip" "$ue_server_port" "Initial Reachability Check" "N/A" "N/A" "N/A" "2s" "FAILURE - UNREACHABLE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        exit 2 # Specific exit code for this subshell
    else
        log_ue "Server check successful for $ue_server_ip:$ue_server_port."
    fi

    for i in $(seq 1 "$ROUNDS"); do
        log_ue "===== Test Round $i of $ROUNDS for UE $ue_server_ip:$ue_server_port ====="
        # --- Section 1: Standard TCP (Unconstrained Rate) ---
        log_ue "--- Testing Unconstrained TCP ---"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink (Single Stream, Uncapped)" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -J -R" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Downlink (Single Stream, Uncapped)" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -J" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink ($PARALLEL_STREAMS_SUSTAINED Parallel, Uncapped)" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -P $PARALLEL_STREAMS_SUSTAINED -J -R" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Downlink ($PARALLEL_STREAMS_SUSTAINED Parallel, Uncapped)" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -P $PARALLEL_STREAMS_SUSTAINED -J" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"

        # --- Section 2: Rate-Limited TCP ---
        log_ue "--- Testing Rate-Limited TCP ---"
        for rate in "${UPLINK_RATES[@]}"; do
            run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink (Rate Limited: $rate)" \
                "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -b $rate -J -R" || ((failure_count_ue++))
            sleep "$SLEEP_BETWEEN_TESTS"
        done
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink (Rate Limited: $UPLINK_MAX_ATTEMPT_RATE - Expecting Cap)" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -b $UPLINK_MAX_ATTEMPT_RATE -J -R" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        for rate in "${DOWNLINK_RATES[@]}"; do
            run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Downlink (Rate Limited: $rate)" \
                "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -b $rate -J" || ((failure_count_ue++))
            sleep "$SLEEP_BETWEEN_TESTS"
        done

        # --- Section 3: Standard UDP ---
        log_ue "--- Testing Standard UDP ---"
        for rate in "${UPLINK_RATES[@]}"; do
            run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Uplink (Rate: $rate)" \
                "iperf3 -c %SERVER% -p %PORT% -u -b $rate -t $DURATION -J -R" || ((failure_count_ue++))
            sleep "$SLEEP_BETWEEN_TESTS"
        done
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Uplink (Rate: $UPLINK_MAX_ATTEMPT_RATE - Expecting Loss/Cap)" \
            "iperf3 -c %SERVER% -p %PORT% -u -b $UPLINK_MAX_ATTEMPT_RATE -t $DURATION -J -R" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        for rate in "${DOWNLINK_RATES[@]}"; do
            run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Downlink (Rate: $rate)" \
                "iperf3 -c %SERVER% -p %PORT% -u -b $rate -t $DURATION -J" || ((failure_count_ue++))
            sleep "$SLEEP_BETWEEN_TESTS"
        done

        # --- Section 4: Bidirectional Tests ---
        log_ue "--- Testing Bidirectional Traffic ---"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Bidirectional (Uncapped)" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION --bidir -J" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Bidirectional (Rate: $BIDIR_UDP_RATE)" \
            "iperf3 -c %SERVER% -p %PORT% -u -b $BIDIR_UDP_RATE -t $DURATION --bidir -J" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"

        # --- Section 5: Small Packet / High Packet Rate Tests ---
        log_ue "--- Testing Small Packet / High Packet Rate ---"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Uplink (Small Packets: ${SMALL_PACKET_LEN}B, Rate: ${SMALL_PACKET_RATE})" \
            "iperf3 -c %SERVER% -p %PORT% -u -b $SMALL_PACKET_RATE -t $DURATION -l $SMALL_PACKET_LEN -J -R" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Downlink (Small Packets: ${SMALL_PACKET_LEN}B, Rate: ${SMALL_PACKET_RATE})" \
            "iperf3 -c %SERVER% -p %PORT% -u -b $SMALL_PACKET_RATE -t $DURATION -l $SMALL_PACKET_LEN -J" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink (Small MSS: ${SMALL_MSS}B, Uncapped)" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -M $SMALL_MSS -J -R" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Downlink (Small MSS: ${SMALL_MSS}B, Uncapped)" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -M $SMALL_MSS -J" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        local low_rate_small_mss=${UPLINK_RATES[1]}
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Uplink (Small MSS: ${SMALL_MSS}B, Rate: ${low_rate_small_mss})" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -M $SMALL_MSS -b ${low_rate_small_mss} -J -R" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"

        # --- Section 6: Bursty Traffic ---
        log_ue "--- Testing Bursty Traffic ---"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Bursty Uplink (${BURSTY_UPLINK_RATE} for ${BURST_DURATION}s)" \
            "iperf3 -c %SERVER% -p %PORT% -u -b $BURSTY_UPLINK_RATE -t $BURST_DURATION -J -R" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "UDP Bursty Downlink (${BURSTY_DOWNLINK_RATE} for ${BURST_DURATION}s)" \
            "iperf3 -c %SERVER% -p %PORT% -u -b $BURSTY_DOWNLINK_RATE -t $BURST_DURATION -J" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Bursty Uplink ($PARALLEL_STREAMS_BURST parallel, ${BURST_DURATION}s)" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $BURST_DURATION -P $PARALLEL_STREAMS_BURST -J -R" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS"
        run_test_internal "$ue_server_ip" "$ue_server_port" "$ue_logfile" "TCP Bursty Downlink ($PARALLEL_STREAMS_BURST parallel, ${BURST_DURATION}s)" \
            "iperf3 -c %SERVER% -p %PORT% -C bbr -t $BURST_DURATION -P $PARALLEL_STREAMS_BURST -J" || ((failure_count_ue++))
        sleep "$SLEEP_BETWEEN_TESTS" # Final sleep

        log_ue "===== Finished Round $i for UE $ue_server_ip:$ue_server_port. Failures in round: $failure_count_ue ====="
    done

    log_ue "===== All test rounds completed for UE $ue_server_ip:$ue_server_port ====="
    log_ue "Total test failures for this UE across all rounds: $failure_count_ue"
    log_ue "Log file: $ue_logfile"
    exit "$failure_count_ue" # Exit subshell with its failure count
}


# --- Main Cleanup Routines ---
perform_core_cleanup() {
    if [ "$CLEANUP_IN_PROGRESS" -eq 1 ]; then
        main_log "CORE_CLEANUP: Cleanup already in progress, skipping."
        return
    fi
    CLEANUP_IN_PROGRESS=1
    main_log "CORE_CLEANUP: Initiated."

    main_log "CORE_CLEANUP: Terminating child UE test process groups..."
    for ue_key in "${!CHILD_PIDS[@]}"; do
        local child_pgid="${CHILD_PIDS[$ue_key]}" # This is the PID of the subshell, which is also its PGID due to set -m
        if ps -p "$child_pgid" > /dev/null; then # Check if process exists
            main_log "CORE_CLEANUP: Sending SIGTERM to process group -$child_pgid (UE: $ue_key)"
            # Kill the entire process group of the child subshell.
            if ! kill -TERM -- "-$child_pgid" 2>/dev/null ; then # Note the "--" to handle PIDs that might start with "-"
                 main_log "CORE_CLEANUP: Failed to send SIGTERM to PGID -$child_pgid (already exited or permission issue?). Trying PID $child_pgid."
                 kill -TERM "$child_pgid" 2>/dev/null
            fi
        else
            main_log "CORE_CLEANUP: Child PID $child_pgid (UE: $ue_key) not found, likely already exited."
        fi
    done

    main_log "CORE_CLEANUP: Waiting 5s for graceful shutdown of children..."
    sleep 5

    main_log "CORE_CLEANUP: Forcefully terminating any remaining child UE test processes and their iperf3 clients..."
    for ue_key in "${!CHILD_PIDS[@]}"; do
        local child_pgid="${CHILD_PIDS[$ue_key]}"
        if ps -p "$child_pgid" > /dev/null; then
            main_log "CORE_CLEANUP: Child subshell PGID -$child_pgid (UE: $ue_key) still running. Sending SIGKILL."
            kill -KILL -- "-$child_pgid" 2>/dev/null # Kill process group
        fi
        # As a fallback, specifically pkill iperf3 instances for this UE
        local server_ip_cleanup=${ue_key%%:*}
        local server_port_cleanup=${ue_key##*:}
        if [[ "$server_port_cleanup" == "$server_ip_cleanup" ]]; then server_port_cleanup=$DEFAULT_IPERF_PORT; fi
        main_log "CORE_CLEANUP: Force pkill for iperf3 clients for $server_ip_cleanup:$server_port_cleanup"
        pkill -KILL -f "iperf3 -c $server_ip_cleanup -p $server_port_cleanup"
    done
    
    # General pkill for any other iperf3 client that might have escaped, targeting configured servers
    main_log "CORE_CLEANUP: Final general pkill for iperf3 clients to configured servers..."
    local temp_servers_array_cleanup
    IFS=',' read -ra temp_servers_array_cleanup <<< "$SERVERS_CSV"
    for server_entry_cleanup in "${temp_servers_array_cleanup[@]}"; do
        local server_ip_general_cleanup=${server_entry_cleanup%%:*}
        pkill -KILL -f "iperf3 -c $server_ip_general_cleanup"
    done

    main_log "CORE_CLEANUP: Finished."
    main_log "Log files: Main: $MAIN_LOGFILE, Summary: $SUMMARY_CSV_FILE, UE logs in $LOG_DIR"
}

interrupted_cleanup() {
    # $? is status of last command; for SIGINT it's 130
    main_log "INTERRUPT SIGNAL RECEIVED (e.g., Ctrl+C). Exit status $?. Cleaning up..."
    trap - SIGINT SIGTERM # Disable these traps to prevent re-entry during cleanup
    perform_core_cleanup
    main_log "Cleanup due to interrupt complete. Exiting script now."
    exit 130 # Standard exit code for interruption by SIGINT
}

normal_exit_cleanup() {
    local exit_status=$? # Capture the script's intended exit status
    main_log "NORMAL SCRIPT EXIT (Status: $exit_status). Cleaning up..."
    # If cleanup was already done by SIGINT/SIGTERM, CLEANUP_IN_PROGRESS will be 1
    if [ "$CLEANUP_IN_PROGRESS" -eq 0 ]; then
        perform_core_cleanup
        if [ "$exit_status" -eq 0 ]; then # Only do long sleep if script was successful overall
            main_log "Normal exit cleanup complete. Script was successful. Sleeping 5 minutes for idle metrics..."
            sleep 300
        else
            main_log "Normal exit cleanup complete. Script had failures. Skipping idle sleep."
        fi
    else
        main_log "Normal exit: Cleanup was already handled by an interrupt signal."
    fi
    main_log "Main script finished."
    # The script will exit with its original $exit_status or 130 if interrupted
}

# Setup traps
trap 'interrupted_cleanup' SIGINT SIGTERM
trap 'normal_exit_cleanup' EXIT


# --- Main Script Logic ---
mkdir -p "$LOG_DIR" # Ensure log directory exists (moved before first log)
if [ ! -d "$LOG_DIR" ]; then
    echo "[CONTROLLER][ERROR] Log directory '$LOG_DIR' could not be created. Exiting." >&2
    exit 1 # Critical error, exit before traps might get confusing
fi

# Initialize Summary CSV file with header (moved before first main_log)
echo "\"RunTimestamp\",\"UE_IP\",\"UE_Port\",\"Test_Description\",\"Cmd_Protocol\",\"Cmd_Direction\",\"Cmd_Rate_Target_Mbps\",\"Cmd_Duration_s\",\"Status\",\"Avg_Mbps\",\"Total_MB_Transferred\",\"UDP_Lost_Packets\",\"UDP_Lost_Percent\",\"UDP_Jitter_ms\",\"TCP_Retransmits\"" > "$SUMMARY_CSV_FILE"

main_log "===== Starting Multi-UE iPerf3 Traffic Simulation (PID: $$) ====="
# ... (rest of main script logic: parsing SERVERS_CSV, reachability checks, launching UE tests in background, waiting for them)
main_log "Target Servers: $SERVERS_CSV"
main_log "Rounds per UE: $ROUNDS"
main_log "Main log file: $MAIN_LOGFILE"
main_log "Summary CSV: $SUMMARY_CSV_FILE"
main_log "Individual UE logs will be in: $LOG_DIR/iperf3_traffic_UE_*"
main_log "============================================================="

IFS=',' read -ra SERVERS_ARRAY <<< "$SERVERS_CSV"

ALL_UES_REACHABLE=true
main_log "Performing initial reachability checks for all specified UEs..."
for server_entry in "${SERVERS_ARRAY[@]}"; do
    server_ip=${server_entry%%:*}
    server_port=${server_entry##*:}
    if [[ "$server_port" == "$server_ip" ]]; then server_port=$DEFAULT_IPERF_PORT; fi
    main_log "Checking UE: $server_ip:$server_port..."
    if ! iperf3 -c "$server_ip" -p "$server_port" -t 2 -J > /dev/null 2>&1; then
        main_log "ERROR: iPerf3 server at $server_ip:$server_port is not reachable."
        append_to_summary "$server_ip" "$server_port" "Pre-Run Reachability Check" "N/A" "N/A" "N/A" "2s" "FAILURE - UNREACHABLE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        ALL_UES_REACHABLE=false
    else
        main_log "UE $server_ip:$server_port is reachable."
    fi
done

if ! $ALL_UES_REACHABLE; then
    main_log "One or more UEs are not reachable. Please check server configurations. Exiting."
    exit 1 # This will trigger 'normal_exit_cleanup'
fi
main_log "All specified UEs are reachable. Proceeding with tests."


for server_entry in "${SERVERS_ARRAY[@]}"; do
    server_ip=${server_entry%%:*}
    server_port=${server_entry##*:}
    if [[ "$server_port" == "$server_ip" ]]; then server_port=$DEFAULT_IPERF_PORT; fi

    main_log "Launching test suite for UE: $server_ip:$server_port in background."
    (run_all_tests_for_single_ue "$server_ip" "$server_port") &
    # $! is the PID of the most recent background command (the subshell)
    CHILD_PIDS["$server_ip:$server_port"]=$! 
    main_log "Test suite for UE $server_ip:$server_port started with subshell PID ${CHILD_PIDS["$server_ip:$server_port"]}"
done

OVERALL_SCRIPT_FAILURE=0
TOTAL_TEST_FAILURES_ACROSS_UES=0

main_log "All UE test suites launched. Waiting for completion..."
for ue_key in "${!CHILD_PIDS[@]}"; do
    pid=${CHILD_PIDS[$ue_key]}
    wait "$pid" # Wait for this specific child subshell to complete
    status=$? # Exit status of the (run_all_tests_for_single_ue) subshell
    
    ue_log_file_path=${UE_LOGFILES[$ue_key]:-"N/A"}

    if [ "$status" -eq 0 ]; then
        main_log "Test suite for UE $ue_key (Subshell PID $pid) completed successfully. Log: $ue_log_file_path"
    elif [ "$status" -eq 2 ]; then # Reachability failure within the UE subshell
        main_log "Test suite for UE $ue_key (Subshell PID $pid) FAILED: Server became unreachable during its run. Log: $ue_log_file_path"
        OVERALL_SCRIPT_FAILURE=1
        TOTAL_TEST_FAILURES_ACROSS_UES=$((TOTAL_TEST_FAILURES_ACROSS_UES + 1)) # Count as 1 major failure for this UE
    else # Other non-zero status means test failures
        main_log "Test suite for UE $ue_key (Subshell PID $pid) completed with $status test failures. Log: $ue_log_file_path"
        OVERALL_SCRIPT_FAILURE=1
        TOTAL_TEST_FAILURES_ACROSS_UES=$((TOTAL_TEST_FAILURES_ACROSS_UES + status))
    fi
done

main_log "===== All concurrent UE test suites have finished ====="
if [ "$OVERALL_SCRIPT_FAILURE" -ne 0 ]; then
    main_log "One or more UEs reported test failures or issues. Total individual test failures across all UEs: $TOTAL_TEST_FAILURES_ACROSS_UES"
else
    main_log "All UEs completed all tests successfully."
fi
main_log "Summary data collected in: $SUMMARY_CSV_FILE"

exit "$OVERALL_SCRIPT_FAILURE" # Triggers 'normal_exit_cleanup'
