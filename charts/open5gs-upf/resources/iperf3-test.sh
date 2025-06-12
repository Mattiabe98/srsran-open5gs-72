#!/bin/bash

set -m # IMPORTANT: Enable Job Control for process group management

# --- Configuration ---
# ... (config remains the same) ...
SERVERS_CSV="$1"
ROUNDS="$2"

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is not installed. Please install jq to use this script."
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
SLEEP_BETWEEN_SYNC_STEPS=7
UPLINK_RATES=("10M" "20M" "35M")
UPLINK_MAX_ATTEMPT_RATE="40M"
DOWNLINK_RATES=("10M" "50M" "100M" "200M" "300M")
BURSTY_UPLINK_RATE="50M"
BURSTY_DOWNLINK_RATE="300M"
BIDIR_UDP_RATE="30M"
SMALL_PACKET_LEN=200
SMALL_PACKET_RATE="2M"
SMALL_MSS=576
PARALLEL_STREAMS_SUSTAINED=10
PARALLEL_STREAMS_BURST=5

# --- Energy Monitoring Configuration ---
RAPL_BASE_PATH="/sys/class/powercap/intel-rapl:0"
ENERGY_UJ_FILE="${RAPL_BASE_PATH}/energy_uj"
MAX_ENERGY_UJ_FILE="${RAPL_BASE_PATH}/max_energy_range_uj"
RAPL_MAX_ENERGY_UJ_FALLBACK="1152921504606846975"
ENERGY_MONITORING_ENABLED=0

# --- Script Setup ---
MAIN_TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
MAIN_LOGFILE="${LOG_DIR}/${MAIN_LOG_BASENAME}_${MAIN_TIMESTAMP}.log"
SUMMARY_CSV_FILE="${LOG_DIR}/${SUMMARY_CSV_BASENAME}_${MAIN_TIMESTAMP}.csv"
# NEW: Temp directory for inter-process communication
TMP_DIR=$(mktemp -d)

declare -A UE_SERVER_IPS
declare -A UE_SERVER_PORTS
declare -A UE_LOGFILES
declare -A ACTIVE_SYNC_STEP_PIDS
SCRIPT_INTERRUPTED_FLAG=0
CORE_CLEANUP_COMPLETED_FLAG=0

# --- Logging and Summary Functions ---
main_log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [CONTROLLER PID:$$] $1" | tee -a "$MAIN_LOGFILE"; }

# Modified to include Num_UEs
append_to_summary() {
    local ue_ip="$1"; local ue_port="$2"; local test_desc="$3"; local cmd_protocol="$4"
    local cmd_direction="$5"; local cmd_rate_target="$6"; local cmd_duration="$7"; local status="$8"
    local avg_mbps="$9"; local total_mb="${10}"; local udp_lost_packets="${11}"
    local udp_lost_percent="${12}"; local udp_jitter_ms="${13}"; local tcp_retransmits="${14}"
    local consumed_energy_uj="${15}"; local efficiency_bits_per_uj="${16}"; local num_ues="${17}"
    echo "\"$MAIN_TIMESTAMP\",\"$ue_ip\",\"$ue_port\",\"$num_ues\",\"$test_desc\",\"$cmd_protocol\",\"$cmd_direction\",\"$cmd_rate_target\",\"$cmd_duration\",\"$status\",\"$avg_mbps\",\"$total_mb\",\"$udp_lost_packets\",\"$udp_lost_percent\",\"$udp_jitter_ms\",\"$tcp_retransmits\",\"$consumed_energy_uj\",\"$efficiency_bits_per_uj\"" >> "$SUMMARY_CSV_FILE"
}

# NEW: Function to write aggregate system-level results
append_to_summary_aggregate() {
    local test_desc="$1"; local num_ues="$2"; local total_mbps="$3"; local total_mb="$4"
    local total_energy_uj="$5"; local total_efficiency="$6"; local duration="$7"
    append_to_summary "AGGREGATE" "N/A" "$test_desc" "N/A" "N/A" "N/A" "$duration" "N/A" "$total_mbps" "$total_mb" "N/A" "N/A" "N/A" "N/A" "$total_energy_uj" "$total_efficiency" "$num_ues"
}

# --- Energy Helper Functions ---
# ... (no changes to energy functions) ...
get_energy_uj() { cat "$ENERGY_UJ_FILE" 2>/dev/null; }
get_max_energy_range_uj() {
    if [ -r "$MAX_ENERGY_UJ_FILE" ]; then
        local max_val; max_val=$(cat "$MAX_ENERGY_UJ_FILE" 2>/dev/null)
        if [[ -n "$max_val" && "$max_val" -gt 0 ]]; then echo "$max_val"; return; fi
    fi
    echo "$RAPL_MAX_ENERGY_UJ_FALLBACK"
}

# --- run_single_test_instance (MODIFIED to write byte count to temp file) ---
run_single_test_instance() {
    # ... (function arguments and setup are the same) ...
    local server_ip=$1; local server_port=$2; local description_base=$3; local full_command_template=$4

    local log_prefix="[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE_TEST_PID:$$] [TARGET: $server_ip:$server_port]"
    
    local description="$description_base (UE: $server_ip:$server_port)"
    local full_command=$(echo "$full_command_template" | sed "s/%SERVER%/$server_ip/g" | sed "s/%PORT%/$server_port/g")
    local cmd_protocol="TCP"; if echo "$full_command" | grep -q -- "-u"; then cmd_protocol="UDP"; fi
    local cmd_direction="Downlink"; if echo "$full_command" | grep -q -- "--bidir"; then cmd_direction="Bidir"; elif echo "$full_command" | grep -q -- "-R"; then cmd_direction="Uplink"; fi
    local cmd_rate_target=$(echo "$full_command" | grep -o -- '-b [^ ]*' | cut -d' ' -f2); if [ -z "$cmd_rate_target" ]; then cmd_rate_target="Uncapped"; fi
    local cmd_duration=$(echo "$full_command" | grep -o -- '-t [0-9]\+' | grep -o '[0-9]\+'); if [[ -z "$cmd_duration" ]]; then cmd_duration="?"; fi
    
    echo "$log_prefix Starting: $description (Duration: ${cmd_duration}s)"
    echo "$log_prefix Command: ${full_command}"

    local energy_start; if [ "$ENERGY_MONITORING_ENABLED" -eq 1 ]; then energy_start=$(get_energy_uj); fi

    local output; local exit_status
    sub_instance_cleanup() { # ... (cleanup trap remains the same) ...
        echo "$log_prefix Sub-instance cleanup for test: $description_base"; pkill -KILL -P $$ 2>/dev/null
        pkill -KILL -f "iperf3 -c $server_ip -p $server_port" 2>/dev/null; }
    trap 'sub_instance_cleanup; exit 130;' SIGINT SIGTERM
    
    if output=$(eval "$full_command" 2>&1); then exit_status=0; else exit_status=$?; fi
    
    local consumed_energy_uj="N/A"; local efficiency_bits_per_uj="N/A"
    if [ "$ENERGY_MONITORING_ENABLED" -eq 1 ] && [ -n "$energy_start" ]; then
        local energy_end; energy_end=$(get_energy_uj)
        if [ -n "$energy_end" ]; then
            consumed_energy_uj=$(( energy_end - energy_start ))
            if (( consumed_energy_uj < 0 )); then
                local max_energy_range; max_energy_range=$(get_max_energy_range_uj)
                consumed_energy_uj=$(( consumed_energy_uj + max_energy_range ))
            fi
        fi
    fi

    if [ "$exit_status" -eq 0 ]; then
        echo -e "\n$output\n"
        echo "$log_prefix Finished: $description - SUCCESS"
        
        calculate_efficiency() { # ... (calculation function remains the same) ...
            local total_bytes_for_calc=$1; local energy_uj_for_calc=$2
            if [[ "$energy_uj_for_calc" == "N/A" || ! "$energy_uj_for_calc" =~ ^[0-9]+$ || "$energy_uj_for_calc" -le 0 || "$total_bytes_for_calc" == "N/A" || ! "$total_bytes_for_calc" =~ ^[0-9]+$ ]]; then echo "N/A"; return; fi
            awk -v bytes="$total_bytes_for_calc" -v uj="$energy_uj_for_calc" 'BEGIN { printf "%.4f", (bytes * 8) / uj }'
        }

        # The logic to parse results and call append_to_summary is the same, but we also save the byte count.
        if [[ "$cmd_direction" == "Bidir" ]]; then
            local total_bytes_ul=$(echo "$output" | jq -r '.end.sum_sent.bytes // 0')
            local total_bytes_dl=$(echo "$output" | jq -r '.end.sum_received.bytes // 0')
            local total_bidir_bytes=$(awk -v ul="$total_bytes_ul" -v dl="$total_bytes_dl" 'BEGIN { print ul + dl }')
            # NEW: Write total bytes to temp file for aggregation. $$ is the subshell's PID.
            echo "$total_bidir_bytes" > "$TMP_DIR/$$.bytes"
            
            local avg_mbps_ul=$(echo "$output" | jq -r '(.end.sum_sent.bits_per_second // 0) / 1000000'); local total_mb_ul=$(echo "$total_bytes_ul" | awk '{printf "%.3f", $1 / (1024*1024)}'); local retrans_ul=$(echo "$output" | jq -r '.end.sum_sent.retransmits // "N/A"')
            local avg_mbps_dl=$(echo "$output" | jq -r '(.end.sum_received.bits_per_second // 0) / 1000000'); local total_mb_dl=$(echo "$total_bytes_dl" | awk '{printf "%.3f", $1 / (1024*1024)}')
            efficiency_bits_per_uj=$(calculate_efficiency "$total_bidir_bytes" "$consumed_energy_uj")
            append_to_summary "$server_ip" "$server_port" "$description (Uplink part)" "TCP" "Bidir-Uplink" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps_ul" "$total_mb_ul" "N/A" "N/A" "N/A" "$retrans_ul" "$consumed_energy_uj" "$efficiency_bits_per_uj" "1"
            append_to_summary "$server_ip" "$server_port" "$description (Downlink part)" "TCP" "Bidir-Downlink" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps_dl" "$total_mb_dl" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "1"
        else
            local total_bytes
            if [[ "$cmd_protocol" == "TCP" && "$cmd_direction" == "Uplink" ]]; then total_bytes=$(echo "$output" | jq -r '.end.sum_sent.bytes // 0')
            elif [[ "$cmd_protocol" == "TCP" && "$cmd_direction" == "Downlink" ]]; then total_bytes=$(echo "$output" | jq -r '.end.sum_received.bytes // 0')
            else total_bytes=$(echo "$output" | jq -r '.end.sum.bytes // 0'); fi # UDP
            # NEW: Write total bytes to temp file for aggregation.
            echo "$total_bytes" > "$TMP_DIR/$$.bytes"
            
            # ... (rest of parsing and calling append_to_summary is the same) ...
            efficiency_bits_per_uj=$(calculate_efficiency "$total_bytes" "$consumed_energy_uj")
            local total_mb=$(echo "$total_bytes" | awk '{printf "%.3f", $1 / (1024*1024)}')
            local avg_mbps; if [[ "$cmd_protocol" == "TCP" ]]; then avg_mbps=$(echo "$total_bytes" | awk -v d="$cmd_duration" '{printf "%.4f", ($1*8)/(d*1000000)}'); else avg_mbps=$(echo "$output" | jq -r '(.end.sum.bits_per_second // 0) / 1000000'); fi
            local retrans="N/A"; if [[ "$cmd_protocol" == "TCP" && "$cmd_direction" == "Uplink" ]]; then retrans=$(echo "$output" | jq -r '.end.sum_sent.retransmits // "N/A"'); fi
            local lost_p="N/A"; local lost_pct="N/A"; local jitter="N/A"; if [[ "$cmd_protocol" == "UDP" ]]; then lost_p=$(echo "$output" | jq -r '.end.sum.lost_packets // "N/A"'); lost_pct=$(echo "$output" | jq -r '.end.sum.lost_percent // "N/A"'); jitter=$(echo "$output" | jq -r '.end.sum.jitter_ms // "N/A"'); fi
            append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps" "$total_mb" "$lost_p" "$lost_pct" "$jitter" "$retrans" "$consumed_energy_uj" "$efficiency_bits_per_uj" "1"
        fi
        exit 0 
    else # Failure case
        # ... (failure case is the same) ...
        echo "$log_prefix Finished: $description - FAILURE (Exit Code: $exit_status)"
        echo "$log_prefix Error Output/Details:"; echo "$output" | sed 's/^/  /'
        append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "FAILURE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "$consumed_energy_uj" "N/A" "1"
        exit 1
    fi
}

# --- Main Cleanup Routines (MODIFIED to include temp dir cleanup) ---
# ... (core cleanup remains the same) ...
perform_core_cleanup() { # ...
    if [ "$CORE_CLEANUP_COMPLETED_FLAG" -eq 1 ]; then main_log "CORE_CLEANUP: Already performed."; return; fi
    CORE_CLEANUP_COMPLETED_FLAG=1; main_log "CORE_CLEANUP: Initiating..."
    main_log "CORE_CLEANUP: Terminating PIDs for current sync step: ${!ACTIVE_SYNC_STEP_PIDS[@]}"
    for ue_key_from_active_pids in "${!ACTIVE_SYNC_STEP_PIDS[@]}"; do
        local pid_to_kill="${ACTIVE_SYNC_STEP_PIDS[$ue_key_from_active_pids]}"
        if ps -p "$pid_to_kill" > /dev/null; then
            main_log "CORE_CLEANUP: Sending SIGTERM to process group -$pid_to_kill (UE: $ue_key_from_active_pids, Subshell PID: $pid_to_kill)"
            kill -TERM -- "-$pid_to_kill" 2>/dev/null 
        fi
    done
    main_log "CORE_CLEANUP: Waiting up to 3s..."; sleep 3
    for ue_key_from_active_pids in "${!ACTIVE_SYNC_STEP_PIDS[@]}"; do
        local pid_to_kill="${ACTIVE_SYNC_STEP_PIDS[$ue_key_from_active_pids]}"
        if ps -p "$pid_to_kill" > /dev/null; then
            main_log "CORE_CLEANUP: PGID -$pid_to_kill (UE: $ue_key_from_active_pids) still running. Sending SIGKILL."
            kill -KILL -- "-$pid_to_kill" 2>/dev/null
        fi
        local server_ip_cleanup=${ue_key_from_active_pids%%:*}; local server_port_cleanup=${ue_key_from_active_pids##*:}
        if [[ "$server_port_cleanup" == "$server_ip_cleanup" ]]; then server_port_cleanup=$DEFAULT_IPERF_PORT; fi
        main_log "CORE_CLEANUP: (Fallback) Force pkill iperf3 to $server_ip_cleanup:$server_port_cleanup"
        pkill -KILL -f "iperf3 -c $server_ip_cleanup -p $server_port_cleanup" 2>/dev/null
    done
    main_log "CORE_CLEANUP: Finished. Logs: Main: $MAIN_LOGFILE, Summary: $SUMMARY_CSV_FILE"
}
handle_main_interrupt() { # ...
    if [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ] && [ "$CORE_CLEANUP_COMPLETED_FLAG" -eq 1 ]; then main_log "INTERRUPT_HANDLER: Already handled. Force exiting."; exit 130;
    elif [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ]; then main_log "INTERRUPT_HANDLER: Already processing. Ignoring."; return; fi
    SCRIPT_INTERRUPTED_FLAG=1; main_log "INTERRUPT_HANDLER: SIGINT/SIGTERM received. Cleaning up..."; trap -- SIGINT SIGTERM
    perform_core_cleanup; main_log "INTERRUPT_HANDLER: Cleanup complete. Exiting script (130)."; exit 130
}
trap 'handle_main_interrupt' SIGINT SIGTERM
handle_main_exit() {
    local final_exit_status=$?
    # NEW: Cleanup temp directory on exit
    if [ -d "$TMP_DIR" ]; then
        main_log "EXIT_HANDLER: Cleaning up temporary directory $TMP_DIR..."
        rm -rf "$TMP_DIR"
    fi
    if [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ]; then main_log "EXIT_HANDLER: Script interrupted. Final status: $final_exit_status."
    else main_log "EXIT_HANDLER: Script exiting (Status: $final_exit_status). Final cleanup."; perform_core_cleanup
        if [ "$final_exit_status" -eq 0 ]; then main_log "EXIT_HANDLER: Success. Sleeping 5m for idle metrics..."; (trap '' SIGINT; sleep 300; trap 'handle_main_interrupt' SIGINT)& local s_pid=$!; wait "$s_pid" || main_log "EXIT_HANDLER: Idle sleep interrupted."
        else main_log "EXIT_HANDLER: Errors (Status: $final_exit_status). Skipping idle sleep."; fi
    fi; main_log "EXIT_HANDLER: Script fully finished."
}
trap 'handle_main_exit' EXIT

# --- Test Definitions (remain the same) ---
# ...

# --- Main Script Logic ---
mkdir -p "$LOG_DIR"; if [ ! -d "$LOG_DIR" ]; then echo "[ERROR] Log dir '$LOG_DIR' failed." >&2; exit 1; fi

# MODIFIED: New CSV Header with Num_UEs
echo "\"RunTimestamp\",\"UE_IP\",\"UE_Port\",\"Num_UEs\",\"Test_Description\",\"Cmd_Protocol\",\"Cmd_Direction\",\"Cmd_Rate_Target_Mbps\",\"Cmd_Duration_s\",\"Status\",\"Avg_Mbps\",\"Total_MB_Transferred\",\"UDP_Lost_Packets\",\"UDP_Lost_Percent\",\"UDP_Jitter_ms\",\"TCP_Retransmits\",\"Consumed_Energy_uJ\",\"Efficiency_bits_per_uJ\"" > "$SUMMARY_CSV_FILE"

# ... (initial logging and energy check are the same) ...
main_log "===== Starting Synchronized Multi-UE iPerf3 Traffic Simulation (PID: $$) ====="
main_log "Target Servers: $SERVERS_CSV"; main_log "Rounds per UE: $ROUNDS"
energy_test_val=$(get_energy_uj)
if [[ -n "$energy_test_val" && "$energy_test_val" =~ ^[0-9]+$ ]]; then
    ENERGY_MONITORING_ENABLED=1
    main_log "Energy monitoring ENABLED (Successfully read from RAPL file: $ENERGY_UJ_FILE)."
else
    ENERGY_MONITORING_ENABLED=0
    main_log "WARN: Energy monitoring DISABLED (Could not read a valid number from RAPL file: $ENERGY_UJ_FILE)."
fi
# ... (UE setup loop is the same) ...
IFS=',' read -ra SERVERS_ARRAY_CONFIG <<< "$SERVERS_CSV"
declare -a UE_KEYS 
for server_entry in "${SERVERS_ARRAY_CONFIG[@]}"; do
    server_ip=${server_entry%%:*}; server_port=${server_entry##*:}
    if [[ "$server_port" == "$server_ip" ]]; then server_port=$DEFAULT_IPERF_PORT; fi
    ue_key="${server_ip}:${server_port}"
    UE_KEYS+=("$ue_key")
    UE_SERVER_IPS["$ue_key"]="$server_ip"
    UE_SERVER_PORTS["$ue_key"]="$server_port"
    ue_id_for_log=$(echo "$server_ip" | tr '.' '_')_"$server_port"
    UE_LOGFILES["$ue_key"]="${LOG_DIR}/iperf3_traffic_UE_${ue_id_for_log}_${MAIN_TIMESTAMP}.log"
    main_log "UE $ue_key will log detailed output to: ${UE_LOGFILES["$ue_key"]}"
    echo "===== iPerf3 Test Log for UE $ue_key (Run Timestamp: $MAIN_TIMESTAMP) =====" > "${UE_LOGFILES["$ue_key"]}"
done
# ... (reachability check is the same) ...
main_log "Performing initial reachability checks..."
ALL_UES_REACHABLE=true
for ue_key in "${UE_KEYS[@]}"; do
    server_ip=${UE_SERVER_IPS["$ue_key"]}; server_port=${UE_SERVER_PORTS["$ue_key"]}
    main_log "Checking UE: $server_ip:$server_port..."
    if ! iperf3 -c "$server_ip" -p "$server_port" -t 2 -J > /dev/null 2>&1; then
        main_log "ERROR: UE $server_ip:$server_port not reachable."
        append_to_summary "Pre-Run Reachability Check" "N/A" "N/A" "2s" "FAILURE - UNREACHABLE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "1"
        ALL_UES_REACHABLE=false
    else main_log "UE $server_ip:$server_port is reachable."; fi
done
if ! $ALL_UES_REACHABLE; then main_log "One or more UEs not reachable. Exiting."; exit 1; fi
main_log "All specified UEs reachable. Proceeding."

OVERALL_SCRIPT_FAILURE=0; TOTAL_TEST_FAILURES_ACROSS_UES=0

# --- MODIFIED: Main test loop now with aggregation logic ---
for r in $(seq 1 "$ROUNDS"); do
    # MODIFIED: Progress indicator
    main_log "===== Starting Round $r/$ROUNDS ====="
    test_num=0
    for test_definition_str in "${TEST_DEFINITIONS[@]}"; do
        ((test_num++))
        IFS='|' read -r description_base command_template <<< "$test_definition_str"
        main_log "--- Round $r/$ROUNDS, Sync Step $test_num: Starting test type: '$description_base' for all UEs ---"
        
        # NEW: Measure energy for the whole step
        step_energy_start=0
        if [ "$ENERGY_MONITORING_ENABLED" -eq 1 ]; then
            step_energy_start=$(get_energy_uj)
        fi

        ACTIVE_SYNC_STEP_PIDS=()
        for ue_key in "${UE_KEYS[@]}"; do
            server_ip=${UE_SERVER_IPS["$ue_key"]}; server_port=${UE_SERVER_PORTS["$ue_key"]}; ue_main_logfile=${UE_LOGFILES["$ue_key"]}
            ( run_single_test_instance "$server_ip" "$server_port" "$description_base" "$command_template" ) >> "$ue_main_logfile" 2>&1 &
            test_pid=$! 
            ACTIVE_SYNC_STEP_PIDS["$ue_key"]=$test_pid
            main_log "Round $r, Step $test_num: Launched '$description_base' for $ue_key (PID: $test_pid)"
        done

        main_log "Round $r, Step $test_num: All instances for '$description_base' launched. Waiting for completion..."
        current_step_failures=0
        declare -A step_success_pids
        for ue_key_for_wait in "${!ACTIVE_SYNC_STEP_PIDS[@]}"; do
            pid_to_wait=${ACTIVE_SYNC_STEP_PIDS[$ue_key_for_wait]}
            wait "$pid_to_wait"; status=$?
            if [ "$status" -ne 0 ]; then
                main_log "Round $r, Step $test_num: Test '$description_base' FAILED for $ue_key_for_wait (PID: $pid_to_wait) with status $status."
                ((current_step_failures++)); ((TOTAL_TEST_FAILURES_ACROSS_UES++)); OVERALL_SCRIPT_FAILURE=1
            else
                main_log "Round $r, Step $test_num: Test '$description_base' SUCCESS for $ue_key_for_wait (PID: $pid_to_wait)."
                step_success_pids["$pid_to_wait"]=1
            fi
        done

        # --- NEW: Aggregation logic after all tests in a step are complete ---
        step_consumed_energy_uj="N/A"
        if [ "$ENERGY_MONITORING_ENABLED" -eq 1 ] && [ -n "$step_energy_start" ]; then
            step_energy_end=$(get_energy_uj)
            if [ -n "$step_energy_end" ]; then
                step_consumed_energy_uj=$(( step_energy_end - step_energy_start ))
                if (( step_consumed_energy_uj < 0 )); then
                    max_e=$(get_max_energy_range_uj); step_consumed_energy_uj=$(( step_consumed_energy_uj + max_e ))
                fi
            fi
        fi

        step_total_bytes=0
        num_successful_ues=0
        for pid in "${!step_success_pids[@]}"; do
            if [ -f "$TMP_DIR/$pid.bytes" ]; then
                bytes_from_ue=$(cat "$TMP_DIR/$pid.bytes")
                step_total_bytes=$(( step_total_bytes + bytes_from_ue ))
                ((num_successful_ues++))
            fi
        done
        rm -f "$TMP_DIR"/*.bytes # Clean up for next step

        if (( num_successful_ues > 0 )); then
            local step_duration=$(echo "$command_template" | grep -o -- '-t [0-9]\+' | grep -o '[0-9]\+')
            local total_mb=$(awk -v b="$step_total_bytes" 'BEGIN {printf "%.3f", b/(1024*1024)}')
            local total_mbps=$(awk -v b="$step_total_bytes" -v d="$step_duration" 'BEGIN {printf "%.4f", (b*8)/(d*1000000)}')
            local aggregate_efficiency=$(calculate_efficiency "$step_total_bytes" "$step_consumed_energy_uj")
            main_log "AGGREGATE [${description_base}]: UEs: ${num_successful_ues}, Total_MB: ${total_mb}, Total_Mbps: ${total_mbps}, Energy_uJ: ${step_consumed_energy_uj}, Efficiency_b/uJ: ${aggregate_efficiency}"
            append_to_summary_aggregate "$description_base" "$num_successful_ues" "$total_mbps" "$total_mb" "$step_consumed_energy_uj" "$aggregate_efficiency" "$step_duration"
        fi
        
        main_log "--- Round $r, Sync Step $test_num: Finished test type: '$description_base'. Failures in this step: $current_step_failures ---"
        if [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ]; then main_log "Interrupt detected after a sync step, aborting."; break; fi
        main_log "Sleeping for ${SLEEP_BETWEEN_SYNC_STEPS}s..."; sleep "$SLEEP_BETWEEN_SYNC_STEPS"
    done 
    if [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ]; then main_log "Interrupt detected, aborting rounds."; break; fi
    main_log "===== Finished Round $r/$ROUNDS ====="
done 

declare -A ACTIVE_SYNC_STEP_PIDS=()
main_log "===== All test rounds and synchronized steps finished ====="
if [ "$OVERALL_SCRIPT_FAILURE" -ne 0 ]; then main_log "SCRIPT COMPLETED WITH ERRORS. Total individual test failures: $TOTAL_TEST_FAILURES_ACROSS_UES"
else main_log "SCRIPT COMPLETED SUCCESSFULLY. All tests passed for all UEs."; fi

exit "$OVERALL_SCRIPT_FAILURE"
