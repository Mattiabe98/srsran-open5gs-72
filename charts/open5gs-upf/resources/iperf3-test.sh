#!/bin/bash

set -m # IMPORTANT: Enable Job Control for process group management

# --- Configuration ---
# ... (all config remains the same) ...
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
UPLINK_RATES=("10M" "20M""35M")
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

declare -A UE_SERVER_IPS
declare -A UE_SERVER_PORTS
declare -A UE_LOGFILES
declare -A ACTIVE_SYNC_STEP_PIDS
SCRIPT_INTERRUPTED_FLAG=0
CORE_CLEANUP_COMPLETED_FLAG=0

# --- Logging and Summary Functions ---
main_log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [CONTROLLER PID:$$] $1" | tee -a "$MAIN_LOGFILE"; }
append_to_summary() {
    local ue_ip="$1"; local ue_port="$2"; local test_desc="$3"; local cmd_protocol="$4"
    local cmd_direction="$5"; local cmd_rate_target="$6"; local cmd_duration="$7"; local status="$8"
    local avg_mbps="$9"; local total_mb="${10}"; local udp_lost_packets="${11}"
    local udp_lost_percent="${12}"; local udp_jitter_ms="${13}"; local tcp_retransmits="${14}"
    local consumed_energy_uj="${15}"; local efficiency_bits_per_uj="${16}"
    echo "\"$MAIN_TIMESTAMP\",\"$ue_ip\",\"$ue_port\",\"$test_desc\",\"$cmd_protocol\",\"$cmd_direction\",\"$cmd_rate_target\",\"$cmd_duration\",\"$status\",\"$avg_mbps\",\"$total_mb\",\"$udp_lost_packets\",\"$udp_lost_percent\",\"$udp_jitter_ms\",\"$tcp_retransmits\",\"$consumed_energy_uj\",\"$efficiency_bits_per_uj\"" >> "$SUMMARY_CSV_FILE"
}

# --- Energy Helper Functions ---
get_energy_uj() {
    cat "$ENERGY_UJ_FILE" 2>/dev/null
}

get_max_energy_range_uj() {
    if [ -r "$MAX_ENERGY_UJ_FILE" ]; then
        local max_val
        max_val=$(cat "$MAX_ENERGY_UJ_FILE" 2>/dev/null)
        if [[ -n "$max_val" && "$max_val" -gt 0 ]]; then
            echo "$max_val"
            return
        fi
    fi
    echo "$RAPL_MAX_ENERGY_UJ_FALLBACK"
}

# --- run_single_test_instance (MODIFIED to use awk) ---
run_single_test_instance() {
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

    local energy_start
    if [ "$ENERGY_MONITORING_ENABLED" -eq 1 ]; then
        energy_start=$(get_energy_uj)
    fi

    local output; local exit_status
    sub_instance_cleanup() {
        echo "$log_prefix Sub-instance cleanup for test: $description_base"
        pkill -KILL -P $$ 2>/dev/null
        pkill -KILL -f "iperf3 -c $server_ip -p $server_port" 2>/dev/null
    }
    trap 'sub_instance_cleanup; exit 130;' SIGINT SIGTERM
    
    if output=$(eval "$full_command" 2>&1); then
        exit_status=0
    else
        exit_status=$?
    fi
    
    local consumed_energy_uj="N/A"
    local efficiency_bits_per_uj="N/A"
    if [ "$ENERGY_MONITORING_ENABLED" -eq 1 ] && [ -n "$energy_start" ]; then
        local energy_end
        energy_end=$(get_energy_uj)
        if [ -n "$energy_end" ]; then
            consumed_energy_uj=$(( energy_end - energy_start ))
            if (( consumed_energy_uj < 0 )); then
                local max_energy_range
                max_energy_range=$(get_max_energy_range_uj)
                consumed_energy_uj=$(( consumed_energy_uj + max_energy_range ))
            fi
        fi
    fi

    if [ "$exit_status" -eq 0 ]; then
        echo ""
        echo "$output"
        echo ""
        echo "$log_prefix Finished: $description - SUCCESS"
        
        # --- MODIFIED: calculate_efficiency now uses awk for bits/uJ ---
        calculate_efficiency() {
            local total_bytes_for_calc=$1
            local energy_uj_for_calc=$2
            
            # Guard against invalid inputs
            if [[ "$energy_uj_for_calc" == "N/A" || ! "$energy_uj_for_calc" =~ ^[0-9]+$ || "$energy_uj_for_calc" -le 0 ]]; then
                echo "N/A"
                return
            fi
            if [[ "$total_bytes_for_calc" == "N/A" || ! "$total_bytes_for_calc" =~ ^[0-9]+$ ]]; then
                echo "N/A"
                return
            fi
            
            # Use awk for floating point calculation: (bytes * 8) / uJ
            awk -v bytes="$total_bytes_for_calc" -v uj="$energy_uj_for_calc" 'BEGIN { printf "%.4f", (bytes * 8) / uj }'
        }

        if [[ "$cmd_direction" == "Bidir" ]]; then
            local avg_mbps_ul=$(echo "$output" | jq -r '(.end.sum_sent.bits_per_second // 0) / 1000000')
            local total_bytes_ul=$(echo "$output" | jq -r '.end.sum_sent.bytes // 0')
            local total_mb_ul=$(echo "$total_bytes_ul" | awk '{printf "%.3f", $1 / (1024*1024)}')
            local retrans_ul=$(echo "$output" | jq -r '.end.sum_sent.retransmits // "N/A"')
            
            local avg_mbps_dl=$(echo "$output" | jq -r '(.end.sum_received.bits_per_second // 0) / 1000000')
            local total_bytes_dl=$(echo "$output" | jq -r '.end.sum_received.bytes // 0')
            local total_mb_dl=$(echo "$total_bytes_dl" | awk '{printf "%.3f", $1 / (1024*1024)}')
            
            local total_bidir_bytes
            total_bidir_bytes=$(awk -v ul="$total_bytes_ul" -v dl="$total_bytes_dl" 'BEGIN { print ul + dl }')
            
            efficiency_bits_per_uj=$(calculate_efficiency "$total_bidir_bytes" "$consumed_energy_uj")
            append_to_summary "$server_ip" "$server_port" "$description (Uplink part)" "$cmd_protocol" "Bidir-Uplink" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps_ul" "$total_mb_ul" "N/A" "N/A" "N/A" "$retrans_ul" "$consumed_energy_uj" "$efficiency_bits_per_uj"
            append_to_summary "$server_ip" "$server_port" "$description (Downlink part)" "$cmd_protocol" "Bidir-Downlink" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps_dl" "$total_mb_dl" "N/A" "N/A" "N/A" "N/A" "$consumed_energy_uj" "$efficiency_bits_per_uj"
        elif [[ "$cmd_protocol" == "TCP" ]]; then
            local avg_mbps; local tcp_retrans; local total_bytes; local total_mb
            if [[ "$cmd_direction" == "Uplink" ]]; then
                avg_mbps=$(echo "$output" | jq -r '(.end.sum_sent.bits_per_second // 0) / 1000000')
                total_bytes=$(echo "$output" | jq -r '.end.sum_sent.bytes // 0')
                tcp_retrans=$(echo "$output" | jq -r '.end.sum_sent.retransmits // "N/A"')
            else # Downlink
                avg_mbps=$(echo "$output" | jq -r '(.end.sum_received.bits_per_second // 0) / 1000000')
                total_bytes=$(echo "$output" | jq -r '.end.sum_received.bytes // 0')
                tcp_retrans="N/A"
            fi
            total_mb=$(echo "$total_bytes" | awk '{printf "%.3f", $1 / (1024*1024)}')
            efficiency_bits_per_uj=$(calculate_efficiency "$total_bytes" "$consumed_energy_uj")
            append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps" "$total_mb" "N/A" "N/A" "N/A" "$tcp_retrans" "$consumed_energy_uj" "$efficiency_bits_per_uj"
        elif [[ "$cmd_protocol" == "UDP" ]]; then
            local avg_mbps=$(echo "$output" | jq -r '(.end.sum.bits_per_second // 0) / 1000000')
            local total_bytes=$(echo "$output" | jq -r '.end.sum.bytes // 0')
            local total_mb=$(echo "$total_bytes" | awk '{printf "%.3f", $1 / (1024*1024)}')
            local lost_packets=$(echo "$output" | jq -r '.end.sum.lost_packets // "N/A"')
            local lost_percent=$(echo "$output" | jq -r '.end.sum.lost_percent // "N/A"')
            local jitter_ms=$(echo "$output" | jq -r '.end.sum.jitter_ms // "N/A"')
            efficiency_bits_per_uj=$(calculate_efficiency "$total_bytes" "$consumed_energy_uj")
            append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "SUCCESS" "$avg_mbps" "$total_mb" "$lost_packets" "$lost_percent" "$jitter_ms" "N/A" "$consumed_energy_uj" "$efficiency_bits_per_uj"
        fi
        exit 0 
    else
        echo "$log_prefix Finished: $description - FAILURE (Exit Code: $exit_status)"
        echo "$log_prefix Error Output/Details:"
        echo "$output" | sed 's/^/  /'
        append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" "FAILURE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "$consumed_energy_uj" "N/A"
        exit 1
    fi
}


# --- Main Logic ---
# ... (no changes in cleanup or test definitions) ...
perform_core_cleanup() {
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
handle_main_interrupt() {
    if [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ] && [ "$CORE_CLEANUP_COMPLETED_FLAG" -eq 1 ]; then main_log "INTERRUPT_HANDLER: Already handled. Force exiting."; exit 130;
    elif [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ]; then main_log "INTERRUPT_HANDLER: Already processing. Ignoring."; return; fi
    SCRIPT_INTERRUPTED_FLAG=1; main_log "INTERRUPT_HANDLER: SIGINT/SIGTERM received. Cleaning up..."; trap -- SIGINT SIGTERM
    perform_core_cleanup; main_log "INTERRUPT_HANDLER: Cleanup complete. Exiting script (130)."; exit 130
}
trap 'handle_main_interrupt' SIGINT SIGTERM
handle_main_exit() {
    local final_exit_status=$?;
    if [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ]; then main_log "EXIT_HANDLER: Script interrupted. Final status: $final_exit_status."
    else main_log "EXIT_HANDLER: Script exiting (Status: $final_exit_status). Final cleanup."; perform_core_cleanup
        if [ "$final_exit_status" -eq 0 ]; then main_log "EXIT_HANDLER: Success. Sleeping 5m for idle metrics..."; (trap '' SIGINT; sleep 300; trap 'handle_main_interrupt' SIGINT)& local s_pid=$!; wait "$s_pid" || main_log "EXIT_HANDLER: Idle sleep interrupted."
        else main_log "EXIT_HANDLER: Errors (Status: $final_exit_status). Skipping idle sleep."; fi
    fi; main_log "EXIT_HANDLER: Script fully finished."
}
trap 'handle_main_exit' EXIT

TEST_DEFINITIONS=(
    "TCP Uplink (Single Stream, Uncapped)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -J -R"
    "TCP Downlink (Single Stream, Uncapped)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -J"
    "TCP Uplink ($PARALLEL_STREAMS_SUSTAINED Parallel, Uncapped)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -P $PARALLEL_STREAMS_SUSTAINED -J -R"
    "TCP Downlink ($PARALLEL_STREAMS_SUSTAINED Parallel, Uncapped)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -P $PARALLEL_STREAMS_SUSTAINED -J"
)
for rate in "${UPLINK_RATES[@]}"; do TEST_DEFINITIONS+=("TCP Uplink (Rate Limited: $rate)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -b $rate -J -R"); done
TEST_DEFINITIONS+=("TCP Uplink (Rate Limited: $UPLINK_MAX_ATTEMPT_RATE - Expecting Cap)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -b $UPLINK_MAX_ATTEMPT_RATE -J -R")
for rate in "${DOWNLINK_RATES[@]}"; do TEST_DEFINITIONS+=("TCP Downlink (Rate Limited: $rate)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -b $rate -J"); done
for rate in "${UPLINK_RATES[@]}"; do TEST_DEFINITIONS+=("UDP Uplink (Rate: $rate)|iperf3 -c %SERVER% -p %PORT% -u -b $rate -t $DURATION -J -R"); done
TEST_DEFINITIONS+=("UDP Uplink (Rate: $UPLINK_MAX_ATTEMPT_RATE - Expecting Loss/Cap)|iperf3 -c %SERVER% -p %PORT% -u -b $UPLINK_MAX_ATTEMPT_RATE -t $DURATION -J -R")
for rate in "${DOWNLINK_RATES[@]}"; do TEST_DEFINITIONS+=("UDP Downlink (Rate: $rate)|iperf3 -c %SERVER% -p %PORT% -u -b $rate -t $DURATION -J"); done
TEST_DEFINITIONS+=("TCP Bidirectional (Uncapped)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION --bidir -J")
TEST_DEFINITIONS+=("UDP Bidirectional (Rate: $BIDIR_UDP_RATE)|iperf3 -c %SERVER% -p %PORT% -u -b $BIDIR_UDP_RATE -t $DURATION --bidir -J")
TEST_DEFINITIONS+=("UDP Uplink (Small Packets: ${SMALL_PACKET_LEN}B, Rate: ${SMALL_PACKET_RATE})|iperf3 -c %SERVER% -p %PORT% -u -b $SMALL_PACKET_RATE -t $DURATION -l $SMALL_PACKET_LEN -J -R")
TEST_DEFINITIONS+=("UDP Downlink (Small Packets: ${SMALL_PACKET_LEN}B, Rate: ${SMALL_PACKET_RATE})|iperf3 -c %SERVER% -p %PORT% -u -b $SMALL_PACKET_RATE -t $DURATION -l $SMALL_PACKET_LEN -J")
TEST_DEFINITIONS+=("TCP Uplink (Small MSS: ${SMALL_MSS}B, Uncapped)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -M $SMALL_MSS -J -R")
TEST_DEFINITIONS+=("TCP Downlink (Small MSS: ${SMALL_MSS}B, Uncapped)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -M $SMALL_MSS -J")
low_rate_small_mss=${UPLINK_RATES[1]}
TEST_DEFINITIONS+=("TCP Uplink (Small MSS: ${SMALL_MSS}B, Rate: ${low_rate_small_mss})|iperf3 -c %SERVER% -p %PORT% -C bbr -t $DURATION -M $SMALL_MSS -b ${low_rate_small_mss} -J -R")
TEST_DEFINITIONS+=("UDP Bursty Uplink (${BURSTY_UPLINK_RATE} for ${BURST_DURATION}s)|iperf3 -c %SERVER% -p %PORT% -u -b $BURSTY_UPLINK_RATE -t $BURST_DURATION -J -R")
TEST_DEFINITIONS+=("UDP Bursty Downlink (${BURSTY_DOWNLINK_RATE} for ${BURST_DURATION}s)|iperf3 -c %SERVER% -p %PORT% -u -b $BURSTY_DOWNLINK_RATE -t $BURST_DURATION -J")
TEST_DEFINITIONS+=("TCP Bursty Uplink ($PARALLEL_STREAMS_BURST parallel, ${BURST_DURATION}s)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $BURST_DURATION -P $PARALLEL_STREAMS_BURST -J -R")
TEST_DEFINITIONS+=("TCP Bursty Downlink ($PARALLEL_STREAMS_BURST parallel, ${BURST_DURATION}s)|iperf3 -c %SERVER% -p %PORT% -C bbr -t $BURST_DURATION -P $PARALLEL_STREAMS_BURST -J")

mkdir -p "$LOG_DIR"; if [ ! -d "$LOG_DIR" ]; then echo "[ERROR] Log dir '$LOG_DIR' failed." >&2; exit 1; fi

# --- MODIFIED: Updated CSV header for the new efficiency metric ---
echo "\"RunTimestamp\",\"UE_IP\",\"UE_Port\",\"Test_Description\",\"Cmd_Protocol\",\"Cmd_Direction\",\"Cmd_Rate_Target_Mbps\",\"Cmd_Duration_s\",\"Status\",\"Avg_Mbps\",\"Total_MB_Transferred\",\"UDP_Lost_Packets\",\"UDP_Lost_Percent\",\"UDP_Jitter_ms\",\"TCP_Retransmits\",\"Consumed_Energy_uJ\",\"Efficiency_bits_per_uJ\"" > "$SUMMARY_CSV_FILE"

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

main_log "Performing initial reachability checks..."
ALL_UES_REACHABLE=true
for ue_key in "${UE_KEYS[@]}"; do
    server_ip=${UE_SERVER_IPS["$ue_key"]}; server_port=${UE_SERVER_PORTS["$ue_key"]}
    main_log "Checking UE: $server_ip:$server_port..."
    if ! iperf3 -c "$server_ip" -p "$server_port" -t 2 -J > /dev/null 2>&1; then
        main_log "ERROR: UE $server_ip:$server_port not reachable."
        append_to_summary "$server_ip" "$server_port" "Pre-Run Reachability Check" "N/A" "N/A" "N/A" "2s" "FAILURE - UNREACHABLE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        ALL_UES_REACHABLE=false
    else main_log "UE $server_ip:$server_port is reachable."; fi
done
if ! $ALL_UES_REACHABLE; then main_log "One or more UEs not reachable. Exiting."; exit 1; fi
main_log "All specified UEs reachable. Proceeding."

OVERALL_SCRIPT_FAILURE=0; TOTAL_TEST_FAILURES_ACROSS_UES=0

for r in $(seq 1 "$ROUNDS"); do
    main_log "===== Starting Round $r of $ROUNDS ====="
    test_num=0
    for test_definition_str in "${TEST_DEFINITIONS[@]}"; do
        ((test_num++))
        IFS='|' read -r description_base command_template <<< "$test_definition_str"
        main_log "--- Round $r, Sync Step $test_num: Starting test type: '$description_base' for all UEs ---"
        
        ACTIVE_SYNC_STEP_PIDS=()

        for ue_key in "${UE_KEYS[@]}"; do
            server_ip=${UE_SERVER_IPS["$ue_key"]}
            server_port=${UE_SERVER_PORTS["$ue_key"]}
            ue_main_logfile=${UE_LOGFILES["$ue_key"]}

            (
                run_single_test_instance "$server_ip" "$server_port" "$description_base" "$command_template"
            ) >> "$ue_main_logfile" 2>&1 &
            
            test_pid=$! 
            ACTIVE_SYNC_STEP_PIDS["$ue_key"]=$test_pid
            main_log "Round $r, Step $test_num: Launched '$description_base' for $ue_key (PID: $test_pid)"
        done

        main_log "Round $r, Step $test_num: All instances for '$description_base' launched. Waiting for completion..."
        current_step_failures=0

        for ue_key_for_wait in "${!ACTIVE_SYNC_STEP_PIDS[@]}"; do
            pid_to_wait=${ACTIVE_SYNC_STEP_PIDS[$ue_key_for_wait]}
            wait "$pid_to_wait"
            status=$?
            if [ "$status" -ne 0 ]; then
                main_log "Round $r, Step $test_num: Test '$description_base' FAILED for $ue_key_for_wait (PID: $pid_to_wait) with status $status."
                ((current_step_failures++))
                ((TOTAL_TEST_FAILURES_ACROSS_UES++))
                OVERALL_SCRIPT_FAILURE=1
            else
                main_log "Round $r, Step $test_num: Test '$description_base' SUCCESS for $ue_key_for_wait (PID: $pid_to_wait)."
            fi
        done
        main_log "--- Round $r, Sync Step $test_num: Finished test type: '$description_base'. Failures in this step: $current_step_failures ---"
        
        if [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ]; then main_log "Interrupt detected after a sync step, aborting."; break; fi
        main_log "Sleeping for ${SLEEP_BETWEEN_SYNC_STEPS}s..."; sleep "$SLEEP_BETWEEN_SYNC_STEPS"
    done 
    if [ "$SCRIPT_INTERRUPTED_FLAG" -eq 1 ]; then main_log "Interrupt detected, aborting rounds."; break; fi
    main_log "===== Finished Round $r ====="
done 

declare -A ACTIVE_SYNC_STEP_PIDS=()

main_log "===== All test rounds and synchronized steps finished ====="
if [ "$OVERALL_SCRIPT_FAILURE" -ne 0 ]; then main_log "SCRIPT COMPLETED WITH ERRORS. Total individual test failures: $TOTAL_TEST_FAILURES_ACROSS_UES"
else main_log "SCRIPT COMPLETED SUCCESSFULLY. All tests passed for all UEs."; fi

exit "$OVERALL_SCRIPT_FAILURE"
