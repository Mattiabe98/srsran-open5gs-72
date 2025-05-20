#!/bin/bash

# --- Configuration Arrays ---
# Index 0 for DU0, 1 for DU1, etc.

# Physical Core base for ru_timing_cpu (LC only, SMT sibling unused by srsRAN)
# PC4, PC5, PC6, PC7, PC8, PC9
RU_TIMING_PC_BASE=(4 5 6 7 8 9) # Results in LC4, LC5, LC6, LC7, LC8, LC9

# Physical Core base for "other" 7 threads for DU0, DU1 (more generous SMT)
# DU0: PC11,12,13,14
# DU1: PC15,16,17,18
OTHER_THREADS_GENEROUS_PC_BASE_DU0=(11 12 13 14)
OTHER_THREADS_GENEROUS_PC_BASE_DU1=(15 16 17 18)

# Physical Core base for "other" 7 threads for DU2-DU5 (more packed SMT)
# DU2: PC19,20,21
# DU3: PC22,23,24
# DU4: PC25,26,27
# DU5: PC28,29,30
OTHER_THREADS_PACKED_PC_BASE_DU2=(19 20 21)
OTHER_THREADS_PACKED_PC_BASE_DU3=(22 23 24)
OTHER_THREADS_PACKED_PC_BASE_DU4=(25 26 27)
OTHER_THREADS_PACKED_PC_BASE_DU5=(28 29 30)

# NIC PCI Addresses (Placeholder - REPLACE THESE!)
NIC_PCI_ADDRESSES=(
    "0000:51:11.0" # DU0
    "0000:51:11.4" # DU1
    "0000:51:11.6" # DU2
    "0000:51:09.0" # DU3
    "0000:51:09.2" # DU4
    "0000:51:09.4" # DU5
)

# Base directory for charts
CHARTS_BASE_DIR="charts"

# Function to update YAML and entrypoint.sh for a DU
update_du_config() {
    local du_index=$1
    local du_name_suffix=$2 # "" for du0, "-1" for du1, etc.
    local du_chart_dir="${CHARTS_BASE_DIR}/srsran-5g-du${du_name_suffix}"
    local yaml_file="${du_chart_dir}/resources/gnb-template.yml"
    local entrypoint_file="${du_chart_dir}/resources/entrypoint.sh"

    echo "Processing DU${du_index} (Chart: ${du_chart_dir})"

    if [ ! -f "$yaml_file" ]; then
        echo "ERROR: YAML file not found: $yaml_file"
        return 1
    fi
    if [ ! -f "$entrypoint_file" ]; then
        echo "ERROR: entrypoint.sh not found: $entrypoint_file"
        return 1
    fi

    # Determine core assignments
    local ru_timing_lc=${RU_TIMING_PC_BASE[$du_index]} # e.g., LC4 for DU0
    local dpdk_lc low_prio_lc ru_txrx_lc l1_dl_lc l1_ul_lc l2_cell_lc ru_cpus_lc
    local taskset_cores_array=()
    taskset_cores_array+=(${ru_timing_lc}) # ru_timing uses this LC, SMT sibling unused by srsRAN

    if [ "$du_index" -eq 0 ]; then # DU0 (Platinum) - Generous SMT for other 7 threads
        # PC11, PC12, PC13, PC14
        dpdk_lc=${OTHER_THREADS_GENEROUS_PC_BASE_DU0[0]}                # LC11 (PC11)
        ru_txrx_lc=$((dpdk_lc + 32))                                    # LC43 (PC11 SMT)
        l1_dl_lc=${OTHER_THREADS_GENEROUS_PC_BASE_DU0[1]}               # LC12 (PC12)
        l1_ul_lc=$((l1_dl_lc + 32))                                     # LC44 (PC12 SMT)
        l2_cell_lc=${OTHER_THREADS_GENEROUS_PC_BASE_DU0[2]}             # LC13 (PC13)
        ru_cpus_lc=${OTHER_THREADS_GENEROUS_PC_BASE_DU0[3]}             # LC14 (PC14)
        low_prio_lc=$((ru_cpus_lc + 32))                                # LC46 (PC14 SMT)

        taskset_cores_array+=(${dpdk_lc} ${ru_txrx_lc} ${l1_dl_lc} ${l1_ul_lc} ${l2_cell_lc} ${ru_cpus_lc} ${low_prio_lc})
    elif [ "$du_index" -eq 1 ]; then # DU1 (Gold) - Generous SMT for other 7 threads
        # PC15, PC16, PC17, PC18
        dpdk_lc=${OTHER_THREADS_GENEROUS_PC_BASE_DU1[0]}                # LC15 (PC15)
        ru_txrx_lc=$((dpdk_lc + 32))                                    # LC47 (PC15 SMT)
        l1_dl_lc=${OTHER_THREADS_GENEROUS_PC_BASE_DU1[1]}               # LC16 (PC16)
        l1_ul_lc=$((l1_dl_lc + 32))                                     # LC48 (PC16 SMT)
        l2_cell_lc=${OTHER_THREADS_GENEROUS_PC_BASE_DU1[2]}             # LC17 (PC17)
        ru_cpus_lc=${OTHER_THREADS_GENEROUS_PC_BASE_DU1[3]}             # LC18 (PC18)
        low_prio_lc=$((ru_cpus_lc + 32))                                # LC50 (PC18 SMT)

        taskset_cores_array+=(${dpdk_lc} ${ru_txrx_lc} ${l1_dl_lc} ${l1_ul_lc} ${l2_cell_lc} ${ru_cpus_lc} ${low_prio_lc})
    else # DU2, DU3, DU4, DU5 - Packed SMT for other 7 threads (3 PCs)
        local base_pc_others
        if [ "$du_index" -eq 2 ]; then base_pc_others=("${OTHER_THREADS_PACKED_PC_BASE_DU2[@]}"); fi
        if [ "$du_index" -eq 3 ]; then base_pc_others=("${OTHER_THREADS_PACKED_PC_BASE_DU3[@]}"); fi
        if [ "$du_index" -eq 4 ]; then base_pc_others=("${OTHER_THREADS_PACKED_PC_BASE_DU4[@]}"); fi
        if [ "$du_index" -eq 5 ]; then base_pc_others=("${OTHER_THREADS_PACKED_PC_BASE_DU5[@]}"); fi
        
        # PC_A for DPDK // ru_txrx
        dpdk_lc=${base_pc_others[0]}            # e.g., DU2 uses LC19 (PC19)
        ru_txrx_lc=$((dpdk_lc + 32))            # e.g., DU2 uses LC51 (PC19 SMT)
        # PC_B for L1_DL // L1_UL
        l1_dl_lc=${base_pc_others[1]}           # e.g., DU2 uses LC20 (PC20)
        l1_ul_lc=$((l1_dl_lc + 32))             # e.g., DU2 uses LC52 (PC20 SMT)
        # PC_C for L2 // ru_cpus, and low_prio shares one of these LCs
        l2_cell_lc=${base_pc_others[2]}         # e.g., DU2 uses LC21 (PC21)
        ru_cpus_lc=$((l2_cell_lc + 32))         # e.g., DU2 uses LC53 (PC21 SMT)
        low_prio_lc=${l2_cell_lc}               # low_prio shares with l2_cell on LC21

        taskset_cores_array+=(${dpdk_lc} ${ru_txrx_lc} ${l1_dl_lc} ${l1_ul_lc} ${l2_cell_lc} ${ru_cpus_lc}) # low_prio is already included if it shares with l2_cell_lc
        # If low_prio_lc is different, add it. Here it's sharing with l2_cell_lc.
    fi
    
    local taskset_string=$(IFS=,; echo "${taskset_cores_array[*]}")
    local nic_pci=${NIC_PCI_ADDRESSES[$du_index]}

    echo "  ru_timing_cpu: ${ru_timing_lc} (Dedicated PC)"
    echo "  dpdk_lc: ${dpdk_lc}"
    echo "  low_prio_lc: ${low_prio_lc}"
    echo "  ru_txrx_lc: ${ru_txrx_lc}"
    echo "  l1_dl_lc: ${l1_dl_lc}"
    echo "  l1_ul_lc: ${l1_ul_lc}"
    echo "  l2_cell_lc: ${l2_cell_lc}"
    echo "  ru_cpus_lc: ${ru_cpus_lc}"
    echo "  Taskset: ${taskset_string}"
    echo "  NIC: ${nic_pci}"

    # Update YAML using yq
    yq e ".hal.eal_args = \"--lcores (0-1)@(${dpdk_lc}) -a ${nic_pci}\"" -i "$yaml_file"
    yq e ".expert_execution.affinities.low_priority_cpus = ${low_prio_lc}" -i "$yaml_file"
    yq e ".expert_execution.affinities.ru_timing_cpu = ${ru_timing_lc}" -i "$yaml_file"
    yq e ".expert_execution.affinities.ofh[0].ru_txrx_cpus = ${ru_txrx_lc}" -i "$yaml_file"
    yq e ".expert_execution.cell_affinities[0].l1_dl_cpus = ${l1_dl_lc}" -i "$yaml_file"
    yq e ".expert_execution.cell_affinities[0].l1_ul_cpus = ${l1_ul_lc}" -i "$yaml_file"
    yq e ".expert_execution.cell_affinities[0].l2_cell_cpus = ${l2_cell_lc}" -i "$yaml_file"
    yq e ".expert_execution.cell_affinities[0].ru_cpus = ${ru_cpus_lc}" -i "$yaml_file"
    
    echo "  Updated YAML: $yaml_file"

    # Update entrypoint.sh using sed
    # This assumes the taskset line is unique and identifiable
    # It looks for 'taskset -c CPS_TO_REPLACE /usr/local/bin/srsgnb ...'
    # Or 'taskset -c CPS_TO_REPLACE stdbuf ... /usr/local/bin/srsdu ...'
    sed -i -E "s/(taskset -c )[^ ]+( stdbuf -oL -eL \/usr\/local\/bin\/srsdu)/\1${taskset_string}\2/" "$entrypoint_file"
    sed -i -E "s/(taskset -c )[^ ]+( \/usr\/local\/bin\/srsgnb)/\1${taskset_string}\2/" "$entrypoint_file" # If gnb is used in some entrypoints

    # A more generic pattern if the above are too specific:
    # sed -i -E "s/(taskset -c )[^ ]+( .*\/usr\/local\/bin\/(srsgnb|srsdu))/\1${taskset_string}\2/" "$entrypoint_file"
    
    echo "  Updated entrypoint.sh: $entrypoint_file"
    echo "---"
}

# --- Main Script ---

# DU0 (srsran-5g-du)
update_du_config 0 ""

# DU1 to DU5 (srsran-5g-du-1 to srsran-5g-du-5)
for i in {1..5}; do
    update_du_config "$i" "-$i"
done

echo "All DU configurations updated."
echo "Please review the changes carefully, especially in entrypoint.sh if the sed command wasn't perfect."
echo "Remember to also configure your SST-CP with the new logical core assignments for each tier."
