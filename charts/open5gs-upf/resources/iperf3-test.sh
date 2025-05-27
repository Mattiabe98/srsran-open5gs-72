#!/bin/bash

# --- Configuration ---
SERVERS_CSV="$1"
ROUNDS="$2"

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

LOG_DIR="/mnt/data/downclock-test-multi-ue"
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
SUMMARY_CSV_FILE="${LOG_DIR}/${SUMMARY_CSV_BASENAME}_${MAIN_TIMESTAMP}.csv" # Central summary file

declare -A CHILD_PIDS
declare -A UE_LOGFILES

# Function for main script logging
main_log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [CONTROLLER] $1" | tee -a "$MAIN_LOGFILE"
}

# Function to write to summary CSV
# Takes specific values as arguments
append_to_summary() {
    # Args: ue_ip, ue_port, test_desc, cmd_protocol, cmd_direction, cmd_rate_target, cmd_duration,
    #       status, avg_mbps, total_mb, udp_lost_packets, udp_lost_percent, udp_jitter_ms, tcp_retransmits
    # Ensure CSV quoting for fields that might contain commas or special chars (like description)
    local ue_ip="$1"
    local ue_port="$2"
    local test_desc="$3" # Already a good description
    local cmd_protocol="$4"
    local cmd_direction="$5"
    local cmd_rate_target="$6"
    local cmd_duration="$7"
    local status="$8"
    local avg_mbps="$9"
    local total_mb="${10}"
    local udp_lost_packets="${11}"
    local udp_lost_percent="${12}"
    local udp_jitter_ms="${13}"
    local tcp_retransmits="${14}"

    # MAIN_TIMESTAMP is global from the script start
    echo "\"$MAIN_TIMESTAMP\",\"$ue_ip\",\"$ue_port\",\"$test_desc\",\"$cmd_protocol\",\"$cmd_direction\",\"$cmd_rate_target\",\"$cmd_duration\",\"$status\",\"$avg_mbps\",\"$total_mb\",\"$udp_lost_packets\",\"$udp_lost_percent\",\"$udp_jitter_ms\",\"$tcp_retransmits\"" >> "$SUMMARY_CSV_FILE"
}


# --- run_test_internal Function ---
# This function is called by the backgrounded run_all_tests_for_single_ue
run_test_internal() {
    local server_ip=$1
    local server_port=$2
    local ue_logfile=$3
    local description=$4
    local full_command_template=$5 # Command template with %SERVER% and %PORT% placeholders

    local full_command=$(echo "$full_command_template" | \
                         sed "s/%SERVER%/$server_ip/g" | \
                         sed "s/%PORT%/$server_port/g")

    # Extract test parameters from the command for summary
    local cmd_protocol="TCP" # Default
    if echo "$full_command" | grep -q -- "-u"; then cmd_protocol="UDP"; fi

    local cmd_direction="Downlink" # Default
    if echo "$full_command" | grep -q -- "--bidir"; then
        cmd_direction="Bidir"
    elif echo "$full_command" | grep -q -- "-R"; then
        cmd_direction="Uplink"
    fi

    local cmd_rate_target
    cmd_rate_target=$(echo "$full_command" | grep -o -- '-b [^ ]*' | cut -d' ' -f2)
    if [ -z "$cmd_rate_target" ]; then cmd_rate_target="Uncapped"; fi

    local cmd_duration
    cmd_duration=$(echo "$full_command" | grep -o -- '-t [0-9]\+' | grep -o '[0-9]\+')
    if [[ -z "$cmd_duration" ]]; then cmd_duration="?"; fi


    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Starting: $description (Duration: ${cmd_duration}s)" | tee -a "$ue_logfile"
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Command: ${full_command}" | tee -a "$ue_logfile"

    local output
    local exit_status
    if output=$(eval "$full_command" 2>&1); then
        echo "" >> "$ue_logfile"
        echo "$output" >> "$ue_logfile" # Append JSON output
        echo "" >> "$ue_logfile"
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Finished: $description - SUCCESS" | tee -a "$ue_logfile"

        # Parse JSON and append to summary CSV
        # For Bidir, iperf3 -J gives sum_sent (client perspective UL) and sum_received (client perspective DL)
        if [[ "$cmd_direction" == "Bidir" ]]; then
            # Uplink part of Bidir
            local avg_mbps_ul=$(echo "$output" | jq -r '(.end.sum_sent.bits_per_second // 0) / 1000000')
            local total_mb_ul=$(echo "$output" | jq -r '(.end.sum_sent.bytes // 0) / (1024*1024)')
            local retrans_ul=$(echo "$output" | jq -r '.end.sum_sent.retransmits // "N/A"') # TCP only
            # UDP Bidir sum is in .end.sum but it's combined. iperf3 JSON for UDP Bidir is less clear for separate UL/DL from client.
            # Assuming TCP Bidir for sum_sent/sum_received primarily. For UDP Bidir, this might report client's sent data.
            append_to_summary "$server_ip" "$server_port" "$description (Uplink part)" "$cmd_protocol" "Bidir-Uplink" "$cmd_rate_target" "$cmd_duration" \
                "SUCCESS" "$avg_mbps_ul" "$total_mb_ul" "N/A" "N/A" "N/A" "$retrans_ul"

            # Downlink part of Bidir
            local avg_mbps_dl=$(echo "$output" | jq -r '(.end.sum_received.bits_per_second // 0) / 1000000')
            local total_mb_dl=$(echo "$output" | jq -r '(.end.sum_received.bytes // 0) / (1024*1024)')
            append_to_summary "$server_ip" "$server_port" "$description (Downlink part)" "$cmd_protocol" "Bidir-Downlink" "$cmd_rate_target" "$cmd_duration" \
                "SUCCESS" "$avg_mbps_dl" "$total_mb_dl" "N/A" "N/A" "N/A" "N/A" # Retransmits are typically on sender side
        
        elif [[ "$cmd_protocol" == "TCP" ]]; then
            local avg_mbps tcp_retrans total_mb
            if [[ "$cmd_direction" == "Uplink" ]]; then # TCP Uplink
                avg_mbps=$(echo "$output" | jq -r '(.end.sum_sent.bits_per_second // 0) / 1000000')
                total_mb=$(echo "$output" | jq -r '(.end.sum_sent.bytes // 0) / (1024*1024)')
                tcp_retrans=$(echo "$output" | jq -r '.end.sum_sent.retransmits // "N/A"')
            else # TCP Downlink
                avg_mbps=$(echo "$output" | jq -r '(.end.sum_received.bits_per_second // 0) / 1000000')
                total_mb=$(echo "$output" | jq -r '(.end.sum_received.bytes // 0) / (1024*1024)')
                tcp_retrans="N/A" # Retransmits are from sender, client only sees received for DL
            fi
            append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" \
                "SUCCESS" "$avg_mbps" "$total_mb" "N/A" "N/A" "N/A" "$tcp_retrans"

        elif [[ "$cmd_protocol" == "UDP" ]]; then
            # For UDP, .end.sum contains the relevant client-side stats (sent or received depending on direction)
            # Or server-side stats if server reports back (which it does for UDP client)
            local avg_mbps=$(echo "$output" | jq -r '(.end.sum.bits_per_second // 0) / 1000000')
            local total_mb=$(echo "$output" | jq -r '(.end.sum.bytes // 0) / (1024*1024)')
            local lost_packets=$(echo "$output" | jq -r '.end.sum.lost_packets // "N/A"')
            local lost_percent=$(echo "$output" | jq -r '.end.sum.lost_percent // "N/A"')
            local jitter_ms=$(echo "$output" | jq -r '.end.sum.jitter_ms // "N/A"')
            append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" \
                "SUCCESS" "$avg_mbps" "$total_mb" "$lost_packets" "$lost_percent" "$jitter_ms" "N/A"
        fi
        return 0
    else
        exit_status=$?
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Finished: $description - FAILURE (Exit Code: $exit_status)" | tee -a "$ue_logfile"
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $server_ip:$server_port] Error Output/Details:" | tee -a "$ue_logfile"
        echo "$output" | sed 's/^/  /' >> "$ue_logfile"
        
        # Log failure to summary
        append_to_summary "$server_ip" "$server_port" "$description" "$cmd_protocol" "$cmd_direction" "$cmd_rate_target" "$cmd_duration" \
            "FAILURE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        return 1
    fi
}

# --- Function to run all tests for a SINGLE UE (this will be backgrounded) ---
run_all_tests_for_single_ue() {
    local ue_server_ip=$1
    local ue_server_port=$2
    local ue_id_for_log=$(echo "$ue_server_ip" | tr '.' '_')

    local ue_timestamp=$(date -u +"%Y-%m-%d_%H-%M-%S")
    local ue_logfile="${LOG_DIR}/iperf3_traffic_UE_${ue_id_for_log}_${ue_timestamp}.log"
    UE_LOGFILES["$ue_server_ip:$ue_server_port"]="$ue_logfile" 

    local failure_count_ue=0

    log_ue() {
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S') UTC] [UE: $ue_server_ip:$ue_server_port] $1" | tee -a "$ue_logfile"
    }

    cleanup_ue_processes() {
        log_ue "Signal received. Attempting to clean up iperf3 client processes for $ue_server_ip..."
        pkill -f "iperf3 -c $ue_server_ip -p $ue_server_port" 
        log_ue "UE process for $ue_server_ip:$ue_server_port exiting."
    }
    trap cleanup_ue_processes SIGINT SIGTERM

    log_ue "===== Starting iPerf3 Test Suite for UE: $ue_server_ip:$ue_server_port ====="
    log_ue "Logging to: $ue_logfile (using JSON format)"
    log_ue "Config: DURATION=$DURATION, BURST_DURATION=$BURST_DURATION, SLEEP_BETWEEN_TESTS=$SLEEP_BETWEEN_TESTS, ROUNDS=$ROUNDS ..."
    log_ue "============================================================="

    log_ue "Performing initial server check for $ue_server_ip:$ue_server_port..."
    if ! iperf3 -c "$ue_server_ip" -p "$ue_server_port" -t 2 -J > /dev/null 2>&1; then
        log_ue "ERROR: iPerf3 server at $ue_server_ip:$ue_server_port is not reachable or doesn't respond correctly."
        append_to_summary "$ue_server_ip" "$ue_server_port" "Initial Reachability Check" "N/A" "N/A" "N/A" "2s" \
            "FAILURE - UNREACHABLE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        exit 2
    else
        log_ue "Server check successful for $ue_server_ip:$ue_server_port."
        # Optionally log successful reachability check to summary
        # append_to_summary "$ue_server_ip" "$ue_server_port" "Initial Reachability Check" "N/A" "N/A" "N/A" "2s" \
        #     "SUCCESS" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
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
        sleep "$SLEEP_BETWEEN_TESTS"

        log_ue "===== Finished Round $i for UE $ue_server_ip:$ue_server_port. Total failures in this round for this UE: $failure_count_ue ====="
    done

    log_ue "===== All test rounds completed for UE $ue_server_ip:$ue_server_port ====="
    log_ue "Total test failures for this UE across all rounds: $failure_count_ue"
    log_ue "Log file: $ue_logfile"
    exit "$failure_count_ue"
}


# Function for cleanup on main script exit/interrupt
main_cleanup() {
    main_log "===== Main script interrupted or finished ====="
    main_log "Attempting to send TERM signal to all child UE test processes..."
    for pid in "${!CHILD_PIDS[@]}"; do # Iterate over keys (which are UE_IP:PORT) to get PIDs
        if ps -p "${CHILD_PIDS[$pid]}" > /dev/null; then # Check if PID from value exists
            main_log "Sending SIGTERM to PID ${CHILD_PIDS[$pid]} (UE: $pid)"
            kill -TERM "${CHILD_PIDS[$pid]}"
        fi
    done

    sleep 5 # Give them a moment

    main_log "Checking for any remaining child UE test processes and sending KILL..."
    for pid_key in "${!CHILD_PIDS[@]}"; do
         if ps -p "${CHILD_PIDS[$pid_key]}" > /dev/null; then
            main_log "Sending SIGKILL to PID ${CHILD_PIDS[$pid_key]} (UE: $pid_key) (was still running)"
            kill -KILL "${CHILD_PIDS[$pid_key]}"
        fi
    done
    
    main_log "Attempting to clean up any remaining iperf3 client processes..."
    local temp_servers_array
    IFS=',' read -ra temp_servers_array <<< "$SERVERS_CSV" # Ensure SERVERS_CSV is available or re-parse
    for server_entry in "${temp_servers_array[@]}"; do
        local server_ip_cleanup=${server_entry%%:*}
        pkill -f "iperf3 -c $server_ip_cleanup"
    done

    main_log "Main script log file: $MAIN_LOGFILE"
    main_log "Summary CSV file: $SUMMARY_CSV_FILE"
    main_log "Individual UE logs are in: $LOG_DIR/iperf3_traffic_UE_*"
    main_log "Main script sleeping for 5 minutes to record idle metrics..."
    sleep 300
    main_log "Main script finished."
}

# --- Main Script Logic ---
trap main_cleanup SIGINT SIGTERM EXIT

mkdir -p "$LOG_DIR"
if [ ! -d "$LOG_DIR" ]; then
    echo "[CONTROLLER][ERROR] Log directory '$LOG_DIR' could not be created. Exiting." >&2
    exit 1
fi

# Initialize Summary CSV file with header
echo "\"RunTimestamp\",\"UE_IP\",\"UE_Port\",\"Test_Description\",\"Cmd_Protocol\",\"Cmd_Direction\",\"Cmd_Rate_Target_Mbps\",\"Cmd_Duration_s\",\"Status\",\"Avg_Mbps\",\"Total_MB_Transferred\",\"UDP_Lost_Packets\",\"UDP_Lost_Percent\",\"UDP_Jitter_ms\",\"TCP_Retransmits\"" > "$SUMMARY_CSV_FILE"


main_log "===== Starting Multi-UE iPerf3 Traffic Simulation ====="
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
    if [[ "$server_port" == "$server_ip" ]]; then 
        server_port=$DEFAULT_IPERF_PORT
    fi
    main_log "Checking UE: $server_ip:$server_port..."
    if ! iperf3 -c "$server_ip" -p "$server_port" -t 2 -J > /dev/null 2>&1; then
        main_log "ERROR: iPerf3 server at $server_ip:$server_port is not reachable. This UE will be skipped or script will exit."
        append_to_summary "$server_ip" "$server_port" "Pre-Run Reachability Check" "N/A" "N/A" "N/A" "2s" \
            "FAILURE - UNREACHABLE" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        ALL_UES_REACHABLE=false
    else
        main_log "UE $server_ip:$server_port is reachable."
    fi
done

if ! $ALL_UES_REACHABLE; then
    main_log "One or more UEs are not reachable. Please check server configurations. Exiting."
    exit 1
fi
main_log "All specified UEs are reachable. Proceeding with tests."


for server_entry in "${SERVERS_ARRAY[@]}"; do
    server_ip=${server_entry%%:*}
    server_port=${server_entry##*:}
    if [[ "$server_port" == "$server_ip" ]]; then
        server_port=$DEFAULT_IPERF_PORT
    fi

    main_log "Launching test suite for UE: $server_ip:$server_port in background."
    (run_all_tests_for_single_ue "$server_ip" "$server_port") &
    CHILD_PIDS["$server_ip:$server_port"]=$! # Store PID keyed by "IP:PORT"
    main_log "Test suite for UE $server_ip:$server_port started with PID ${CHILD_PIDS["$server_ip:$server_port"]}"
done

OVERALL_SCRIPT_FAILURE=0
TOTAL_TEST_FAILURES_ACROSS_UES=0

main_log "All UE test suites launched. Waiting for completion..."
for ue_key in "${!CHILD_PIDS[@]}"; do # ue_key is "IP:PORT"
    pid=${CHILD_PIDS[$ue_key]}
    wait "$pid"
    status=$?
    
    ue_log_file_path=${UE_LOGFILES[$ue_key]:-"N/A"}

    if [ "$status" -eq 0 ]; then
        main_log "Test suite for UE $ue_key (PID $pid) completed successfully. Log: $ue_log_file_path"
    elif [ "$status" -eq 2 ]; then
        main_log "Test suite for UE $ue_key (PID $pid) FAILED during its own run: Server became unreachable. Log: $ue_log_file_path"
        OVERALL_SCRIPT_FAILURE=1
        TOTAL_TEST_FAILURES_ACROSS_UES=$((TOTAL_TEST_FAILURES_ACROSS_UES + 1))
    else
        main_log "Test suite for UE $ue_key (PID $pid) completed with $status test failures. Log: $ue_log_file_path"
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

exit "$OVERALL_SCRIPT_FAILURE"
