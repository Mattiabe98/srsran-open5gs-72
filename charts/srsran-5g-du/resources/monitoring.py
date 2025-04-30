#!/usr/bin/env python3

import os
import time
import argparse
import re
import struct
import glob
from collections import defaultdict
from datetime import datetime, timezone

# --- MSR Addresses ---
MSR_IA32_TSC = 0x10
MSR_IA32_MPERF = 0xE7  # Corrected: Reference/Nominal Frequency Clock Counter
MSR_IA32_APERF = 0xE8  # Corrected: Actual Performance Clock Counter
MSR_IA32_THERM_STATUS = 0x19C
MSR_IA32_PACKAGE_THERM_STATUS = 0x1B1
MSR_IA32_TEMPERATURE_TARGET = 0x1A2
# Fixed-Function Performance Counters
MSR_IA32_FIXED_CTR0 = 0x309 # Instructions Retired (PerfEvtSel0)
MSR_IA32_FIXED_CTR1 = 0x30A # Unhalted Core Cycles (PerfEvtSel1)
# Note: We use MSR_IA32_FIXED_CTR0 for instructions as a substitute for perf.
# Note: We use MSR_IA32_APERF (0xE8) for the cycle count in IPC calc, like C turbostat.

# --- Constants ---
MAX_CPUIDLE_STATES = 10
PSTATE_BASE_PATH = "/sys/devices/system/cpu/intel_pstate"

# --- Helper Functions ---
def read_sysfs_int(path):
    try:
        # Use context manager for file handling
        with open(path, 'r') as f:
            return int(f.read().strip())
    except Exception:
        # print(f"Warning: Cannot read int from {path}: {e}") # Optional: reduce noise
        return None

def read_sysfs_str(path):
    try:
        # Use context manager for file handling
        with open(path, 'r') as f:
            return f.read().strip()
    except Exception:
        # print(f"Warning: Cannot read str from {path}: {e}") # Optional: reduce noise
        return None

def read_msr(cpu_id, reg):
    try:
        # Use context manager for file handling
        with open(f'/dev/cpu/{cpu_id}/msr', 'rb') as f: # Read in binary mode 'rb'
            f.seek(reg)
            msr_val_bytes = f.read(8)
            if len(msr_val_bytes) == 8:
                return struct.unpack('<Q', msr_val_bytes)[0] # '<Q' = Little-endian, unsigned 64-bit
            else:
                print(f"Warning: Short read from MSR {hex(reg)} on CPU {cpu_id}")
                return None
    except OSError as e:
        # Only print specific MSR errors once potentially
        # print(f"Warning: Cannot read MSR {hex(reg)} on CPU {cpu_id}: {e}")
        return None
    except Exception as e:
        print(f"Error: Unexpected error reading MSR {hex(reg)} on CPU {cpu_id}: {e}")
        return None


def parse_interrupts():
    irq_counts = defaultdict(int); cpu_columns = {}
    try:
        with open('/proc/interrupts', 'r') as f: lines = f.readlines()
        if not lines: return irq_counts
        header = lines[0].split()
        # Find CPU column indices more robustly
        cpu_pattern = re.compile(r'^CPU(\d+)$')
        for idx, col_name in enumerate(header):
            match = cpu_pattern.match(col_name)
            if match:
                cpu_columns[idx] = int(match.group(1))

        if not cpu_columns: return irq_counts # No CPUs found in header

        for line in lines[1:]:
            parts = line.split()
            # Skip lines not starting with an IRQ number/name or blank lines
            if not parts or not (parts[0].endswith(':') or re.match(r'^[A-Za-z0-9]', parts[0])): continue

            # Start reading counts after the IRQ identifier column(s)
            count_start_col = 1
            # Adjust if there are multiple identifier columns (like "LOC:" before counts)
            while count_start_col < len(parts) and not parts[count_start_col].isdigit():
                 count_start_col += 1

            # Map header column index to data part index
            header_indices = sorted(cpu_columns.keys())
            part_indices = {}
            if len(header_indices) > 0:
                # Assuming counts start right after identifiers
                base_part_idx = count_start_col
                for i, h_idx in enumerate(header_indices):
                    part_indices[h_idx] = base_part_idx + i


            for header_idx, cpu_id in cpu_columns.items():
                part_idx = part_indices.get(header_idx)
                if part_idx is not None and part_idx < len(parts):
                    try: irq_counts[cpu_id] += int(parts[part_idx])
                    except (ValueError, IndexError): continue # Handle missing/non-int data gracefully
                # else: # Optional: Debug if a column is missing data
                #    print(f"Debug: Missing data for CPU{cpu_id} (header idx {header_idx}, expected part idx {part_idx}) in line: {line.strip()}")

    except FileNotFoundError: print("Warning: /proc/interrupts not found.")
    except Exception as e: print(f"Warning: Error parsing /proc/interrupts: {e}")
    return irq_counts

def get_cpu_topology(target_cpus):
    topology = {}
    for cpu_id in target_cpus:
        core_id = read_sysfs_int(f'/sys/devices/system/cpu/cpu{cpu_id}/topology/core_id')
        pkg_id = read_sysfs_int(f'/sys/devices/system/cpu/cpu{cpu_id}/topology/physical_package_id')
        topology[cpu_id] = {'core_id': core_id if core_id is not None else -1,
                            'pkg_id': pkg_id if pkg_id is not None else -1}
    return topology

def get_tjmax(cpu_id):
    tjmax = 100; msr_val = read_msr(cpu_id, MSR_IA32_TEMPERATURE_TARGET)
    if msr_val is not None:
        tcc = (msr_val >> 16) & 0xFF
        if tcc > 0: tjmax = tcc
    return tjmax

def find_rapl_domains():
    domains = {'pkg': [], 'dram': []}; powercap_base = "/sys/class/powercap"
    try:
        if not os.path.isdir(powercap_base): return domains
        # Find top-level package domains first (e.g., intel-rapl:0)
        for path in glob.glob(os.path.join(powercap_base, "intel-rapl:?")): # Match single digit first
            if os.path.isdir(path) and ':' not in os.path.basename(path).split(':')[-1]:
                name = read_sysfs_str(os.path.join(path, "name"))
                energy_path = os.path.join(path, "energy_uj")
                max_energy_path = os.path.join(path, "max_energy_range_uj")
                if name and name.startswith("package") and os.path.exists(energy_path) and os.path.exists(max_energy_path):
                    try:
                        # Extract ID from directory name (more reliable than parsing 'name')
                        id_str = os.path.basename(path).split(':')[-1]
                        id_ = int(id_str)
                        domains['pkg'].append({'id': id_, 'path': energy_path, 'max_path': max_energy_path})
                    except ValueError: # Handle cases like intel-rapl: DNE or non-numeric ID
                         domains['pkg'].append({'id': -1, 'path': energy_path, 'max_path': max_energy_path})
        # Also check for multi-digit package IDs (e.g., intel-rapl:10)
        for path in glob.glob(os.path.join(powercap_base, "intel-rapl:??*")): # Match two or more digits/chars
            if os.path.isdir(path) and ':' not in os.path.basename(path).split(':')[-1]:
                 name = read_sysfs_str(os.path.join(path, "name"))
                 energy_path = os.path.join(path, "energy_uj")
                 max_energy_path = os.path.join(path, "max_energy_range_uj")
                 if name and name.startswith("package") and os.path.exists(energy_path) and os.path.exists(max_energy_path):
                     try:
                         id_str = os.path.basename(path).split(':')[-1]
                         id_ = int(id_str)
                         # Avoid duplicates if already found by single-digit match
                         if not any(d['id'] == id_ for d in domains['pkg']):
                              domains['pkg'].append({'id': id_, 'path': energy_path, 'max_path': max_energy_path})
                     except ValueError: pass # Ignore if ID isn't numeric

        # Find sub-domains like DRAM (e.g., intel-rapl:0:0)
        for path in glob.glob(os.path.join(powercap_base, "intel-rapl:*:?")): # Match sub-domain single digit
             if os.path.isdir(path):
                 name = read_sysfs_str(os.path.join(path, "name"))
                 energy_path = os.path.join(path, "energy_uj")
                 max_energy_path = os.path.join(path, "max_energy_range_uj")
                 if name == "dram" and os.path.exists(energy_path) and os.path.exists(max_energy_path):
                     try:
                         # Extract package ID from parent directory name
                         parent_basename = os.path.basename(os.path.dirname(path))
                         pkg_id_str = parent_basename.split(':')[-1]
                         pkg_id_ = int(pkg_id_str)
                         domains['dram'].append({'id': pkg_id_, 'path': energy_path, 'max_path': max_energy_path})
                     except (ValueError, IndexError): # Handle errors in parsing parent dir name
                          domains['dram'].append({'id': -1, 'path': energy_path, 'max_path': max_energy_path})
        # Also check multi-digit sub-domain IDs (less common but possible)
        for path in glob.glob(os.path.join(powercap_base, "intel-rapl:*:??*")):
            if os.path.isdir(path):
                name = read_sysfs_str(os.path.join(path, "name"))
                energy_path = os.path.join(path, "energy_uj")
                max_energy_path = os.path.join(path, "max_energy_range_uj")
                if name == "dram" and os.path.exists(energy_path) and os.path.exists(max_energy_path):
                    try:
                        parent_basename = os.path.basename(os.path.dirname(path))
                        pkg_id_str = parent_basename.split(':')[-1]
                        pkg_id_ = int(pkg_id_str)
                        # Avoid duplicates
                        if not any(d['id'] == pkg_id_ for d in domains['dram']):
                            domains['dram'].append({'id': pkg_id_, 'path': energy_path, 'max_path': max_energy_path})
                    except (ValueError, IndexError): pass


        # Sort domains by ID for consistent ordering
        domains['pkg'].sort(key=lambda x: x['id']); domains['dram'].sort(key=lambda x: x['id'])
    except Exception as e: print(f"Warning: Error finding RAPL domains: {e}")
    return domains


def get_cpuidle_state_info(cpu_id):
    state_info = {}; base_path = f'/sys/devices/system/cpu/cpu{cpu_id}/cpuidle'
    try:
        if not os.path.isdir(base_path): return state_info
        for i in range(MAX_CPUIDLE_STATES):
            state_dir = os.path.join(base_path, f'state{i}')
            name_path = os.path.join(state_dir, 'name'); time_path = os.path.join(state_dir, 'time')
            # Check existence more efficiently
            if not os.path.isdir(state_dir) or not os.path.exists(name_path) or not os.path.exists(time_path): continue
            name = read_sysfs_str(name_path)
            if name: state_info[name] = {'time': time_path} # Store path, read value later
    except Exception as e: print(f"Warning: Error probing cpuidle for CPU {cpu_id}: {e}")
    return state_info

def get_effective_cpus():
    # Prioritize cgroup v2 path
    paths_to_try = [
        '/sys/fs/cgroup/cpuset.cpus.effective',  # cgroup v2
        '/sys/fs/cgroup/cpuset/cpuset.effective_cpus' # cgroup v1
    ]
    cpu_str = None; path_read = None
    for path in paths_to_try:
        if os.path.exists(path):
            path_read = path
            try:
                with open(path, 'r') as f: cpu_str = f.read().strip()
                if cpu_str:
                    # print(f"Debug: Read effective CPUs from {path_read}: '{cpu_str}'") # Optional debug
                    break # Found a valid string
            except Exception as e: print(f"Warning: Could not read {path}: {e}.")

    # Fallback to process affinity if cgroup paths fail or are empty
    if cpu_str is None or cpu_str == "":
        # print("Debug: Falling back to os.sched_getaffinity") # Optional debug
        try: return sorted(list(os.sched_getaffinity(0)))
        except OSError: print("Error: Cannot get process affinity."); return []
        except AttributeError: print("Error: os.sched_getaffinity not available on this platform."); return list(range(os.cpu_count())) # Further fallback

    # Parse the CPU string (e.g., "0-3,7,10-11")
    cpus = set()
    for part in cpu_str.split(','):
        try:
            part = part.strip()
            if '-' in part:
                start, end = map(int, part.split('-'))
                cpus.update(range(start, end + 1))
            elif part: # Check if part is not empty
                cpus.add(int(part))
        except ValueError: print(f"Warning: Could not parse CPU part '{part}' in effective CPU string '{cpu_str}' from {path_read}")
    return sorted(list(cpus))


def print_pstate_info():
    info = {'min_perf_pct': None, 'max_perf_pct': None, 'status': None, 'no_turbo': None, 'hwp_boost': None}
    if not os.path.exists(PSTATE_BASE_PATH):
        print("intel_pstate sysfs directory not found.")
        return info
    info['status'] = read_sysfs_str(os.path.join(PSTATE_BASE_PATH, "status"))
    info['no_turbo'] = read_sysfs_int(os.path.join(PSTATE_BASE_PATH, "no_turbo"))
    info['hwp_boost'] = read_sysfs_int(os.path.join(PSTATE_BASE_PATH, "hwp_dynamic_boost"))
    # Store paths for later reading in the loop
    info['min_perf_pct_path'] = os.path.join(PSTATE_BASE_PATH, "min_perf_pct")
    info['max_perf_pct_path'] = os.path.join(PSTATE_BASE_PATH, "max_perf_pct")

    print("--- Intel P-State Info ---", flush=True)
    print(f" Status:\t{info['status'] if info['status'] is not None else 'N/A'}", flush=True)
    print(f" No Turbo:\t{info['no_turbo'] if info['no_turbo'] is not None else 'N/A'} (1=disabled, 0=enabled)", flush=True)
    print(f" HWP Boost:\t{info['hwp_boost'] if info['hwp_boost'] is not None else 'N/A'} (1=enabled, 0=disabled)", flush=True)
    print("--------------------------", flush=True)
    return info


# --- Data Structures ---
class CPUData:
    def __init__(self):
        self.timestamp = 0.0
        self.tsc = 0
        self.aperf = 0
        self.mperf = 0
        self.instr_retired = 0 # Added for IPC calculation
        # self.core_cycles = 0 # No longer directly used for IPC, keep if needed elsewhere
        self.irq_count = 0
        self.core_temp = None
        self.core_throttled = False
        self.actual_mhz = None
        self.governor = None
        self.epb = None
        self.min_perf_pct = None
        self.max_perf_pct = None
        self.cstate_time = defaultdict(int) # Stores raw cumulative time_us

    def delta(self, prev):
        if not isinstance(prev, CPUData) or self.timestamp <= prev.timestamp:
             # Allow zero delta if timestamps and TSC match (e.g., very short interval)
             if self.timestamp == prev.timestamp and self.tsc == prev.tsc: pass
             else: return None # Invalid previous data or timestamp order

        # Prevent division by zero later
        if self.tsc < prev.tsc: return None # TSC should not decrease

        d = CPUData();
        d.timestamp = self.timestamp - prev.timestamp
        # Avoid division by zero if interval is extremely short
        if d.timestamp <= 0: d.timestamp = 1e-9 # Set to a tiny positive value

        d.tsc = self.tsc - prev.tsc
        # Handle 64-bit counter wrap-around
        d.aperf = self.aperf - prev.aperf if self.aperf >= prev.aperf else (2**64 - prev.aperf) + self.aperf
        d.mperf = self.mperf - prev.mperf if self.mperf >= prev.mperf else (2**64 - prev.mperf) + self.mperf
        d.instr_retired = self.instr_retired - prev.instr_retired if self.instr_retired >= prev.instr_retired else (2**64 - prev.instr_retired) + self.instr_retired
        # d.core_cycles = self.core_cycles - prev.core_cycles if self.core_cycles >= prev.core_cycles else (2**64 - prev.core_cycles) + self.core_cycles

        # IRQs are cumulative counts from /proc/interrupts, simple subtraction is fine
        d.irq_count = self.irq_count - prev.irq_count

        # These are snapshots from the 'current' reading
        d.core_temp = self.core_temp
        d.core_throttled = self.core_throttled
        d.actual_mhz = self.actual_mhz
        d.governor = self.governor
        d.epb = self.epb
        d.min_perf_pct = self.min_perf_pct
        d.max_perf_pct = self.max_perf_pct

        # Calculate delta for cpuidle times, handling wrap-around
        for name, time_now in self.cstate_time.items():
            time_prev = prev.cstate_time.get(name, 0) # Get previous time, default to 0
            # Assume cpuidle time counters are also 64-bit
            d.cstate_time[name] = time_now - time_prev if time_now >= time_prev else (2**64 - time_prev) + time_now
        return d

def calculate_delta_energy(current_uj, prev_uj, max_range_uj):
    """Calculates energy delta correctly handling wrap-around based on max_range."""
    if max_range_uj is None or max_range_uj <= 0: max_range_uj = 2**63 # Use a large default if max_range unknown/invalid
    if current_uj >= prev_uj: delta = current_uj - prev_uj
    else: delta = (max_range_uj - prev_uj) + current_uj # Wrap-around calculation

    # Sanity check: Delta shouldn't exceed the max range (can happen with buggy drivers/counters)
    if delta > max_range_uj:
        # print(f"Warning: Energy delta ({delta}uJ) exceeded max range ({max_range_uj}uJ). Resetting to 0.")
        return 0
    return delta

class PkgData:
     def __init__(self):
        self.timestamp = 0.0
        self.pkg_temp = None
        self.energy_pkg_uj = 0
        self.energy_dram_uj = 0
        self.max_energy_pkg_uj = 0 # Store max range read from sysfs
        self.max_energy_dram_uj = 0

     def delta(self, prev):
        if not isinstance(prev, PkgData) or self.timestamp <= prev.timestamp: return None
        d = PkgData();
        d.timestamp = self.timestamp - prev.timestamp
        if d.timestamp <= 0: d.timestamp = 1e-9 # Avoid division by zero
        d.pkg_temp = self.pkg_temp # Snapshot

        # Calculate energy delta using the stored max range
        d.energy_pkg_uj = calculate_delta_energy(self.energy_pkg_uj, prev.energy_pkg_uj, self.max_energy_pkg_uj)
        d.energy_dram_uj = calculate_delta_energy(self.energy_dram_uj, prev.energy_dram_uj, self.max_energy_dram_uj)

        # Carry over the max range for reference if needed, though not strictly necessary for delta object
        d.max_energy_pkg_uj = self.max_energy_pkg_uj
        d.max_energy_dram_uj = self.max_energy_dram_uj
        return d

# --- Data Collection ---

def get_all_counters(target_cpus, topology, tjmax, rapl_domains_info, cpuidle_state_info, pstate_paths):
    """Reads all relevant counters using MSR and sysfs for a single point in time."""
    current_irqs = parse_interrupts() # Get IRQ counts at the start
    timestamp = time.monotonic() # Use monotonic clock for intervals

    cpu_data = {cpu: CPUData() for cpu in target_cpus}
    # Determine unique package IDs present in the target CPUs
    all_pkg_ids = {info['pkg_id'] for cpu_id, info in topology.items()
                   if cpu_id in target_cpus and info['pkg_id'] != -1}
    pkg_data = {pkg_id: PkgData() for pkg_id in all_pkg_ids}

    # Read P-State min/max % once per interval
    min_perf = read_sysfs_int(pstate_paths.get('min_perf_pct_path'))
    max_perf = read_sysfs_int(pstate_paths.get('max_perf_pct_path'))

    # --- Read Global/Package values ONCE per interval ---
    # Keep track to read package-level data only once per package
    pkgs_visited_for_temps = set()
    pkgs_visited_for_rapl = set()

    for pkg_id in all_pkg_ids:
        # Find a representative CPU for this package *within the target_cpus list*
        rep_cpu = -1
        for c_id in target_cpus:
            if topology.get(c_id) and topology[c_id]['pkg_id'] == pkg_id:
                rep_cpu = c_id
                break
        if rep_cpu == -1: continue # Should not happen if all_pkg_ids is derived correctly

        p_data = pkg_data[pkg_id]
        p_data.timestamp = timestamp # Set timestamp for package data

        # Read Package Temperature (once per package)
        if pkg_id not in pkgs_visited_for_temps:
            pkg_therm_stat = read_msr(rep_cpu, MSR_IA32_PACKAGE_THERM_STATUS)
            if pkg_therm_stat is not None:
                dts = (pkg_therm_stat >> 16) & 0x7F
                p_data.pkg_temp = tjmax - dts # Use provided tjmax
            pkgs_visited_for_temps.add(pkg_id)

        # Read RAPL Energy (once per package)
        if pkg_id not in pkgs_visited_for_rapl:
            pkg_rapl_info, dram_rapl_info = None, None
            # Find the correct RAPL domain info based on package ID
            for domain in rapl_domains_info.get('pkg', []):
                 if domain['id'] == pkg_id: pkg_rapl_info = domain; break
            # Fallback for systems reporting only one package domain without specific ID
            if not pkg_rapl_info and len(rapl_domains_info.get('pkg', [])) == 1 and rapl_domains_info['pkg'][0]['id'] == -1:
                 if len(all_pkg_ids) == 1: # Only use if there's truly only one package being monitored
                     pkg_rapl_info = rapl_domains_info['pkg'][0]

            for domain in rapl_domains_info.get('dram', []):
                 if domain['id'] == pkg_id: dram_rapl_info = domain; break
            # Fallback for DRAM
            if not dram_rapl_info and len(rapl_domains_info.get('dram', [])) == 1 and rapl_domains_info['dram'][0]['id'] == -1:
                 if len(all_pkg_ids) == 1 or pkg_id == 0: # Heuristic: Assign to pkg 0 or the only pkg
                     dram_rapl_info = rapl_domains_info['dram'][0]

            # Read current energy and max range for correct delta calculation later
            if pkg_rapl_info:
                p_data.max_energy_pkg_uj = read_sysfs_int(pkg_rapl_info['max_path']) # Store max range
                p_data.energy_pkg_uj = read_sysfs_int(pkg_rapl_info['path']) or 0
            if dram_rapl_info:
                p_data.max_energy_dram_uj = read_sysfs_int(dram_rapl_info['max_path']) # Store max range
                p_data.energy_dram_uj = read_sysfs_int(dram_rapl_info['path']) or 0
            pkgs_visited_for_rapl.add(pkg_id)


    # --- Read Per-CPU values ---
    cores_visited_for_temps = set() # Track cores to read core temp once

    for cpu_id in target_cpus:
        data = cpu_data[cpu_id]
        data.timestamp = timestamp
        data.tsc = read_msr(cpu_id, MSR_IA32_TSC) or 0
        data.aperf = read_msr(cpu_id, MSR_IA32_APERF) or 0
        data.mperf = read_msr(cpu_id, MSR_IA32_MPERF) or 0
        data.instr_retired = read_msr(cpu_id, MSR_IA32_FIXED_CTR0) or 0 # Read Inst Retired MSR
        # data.core_cycles = read_msr(cpu_id, MSR_IA32_FIXED_CTR1) or 0 # Still read if needed elsewhere

        # Assign IRQ count gathered earlier
        data.irq_count = current_irqs.get(cpu_id, 0)

        # Read sysfs values for this CPU
        act_mhz_khz = read_sysfs_int(f'/sys/devices/system/cpu/cpu{cpu_id}/cpufreq/scaling_cur_freq')
        data.actual_mhz = act_mhz_khz / 1000 if act_mhz_khz is not None else None
        data.governor = read_sysfs_str(f'/sys/devices/system/cpu/cpu{cpu_id}/cpufreq/scaling_governor')
        data.epb = read_sysfs_int(f'/sys/devices/system/cpu/cpu{cpu_id}/power/energy_perf_bias')
        data.min_perf_pct = min_perf # Assign global value read earlier
        data.max_perf_pct = max_perf # Assign global value read earlier

        # Read cpuidle state times for this CPU
        if cpu_id in cpuidle_state_info:
            for state_name, paths in cpuidle_state_info[cpu_id].items():
                 time_us = read_sysfs_int(paths['time'])
                 if time_us is not None: data.cstate_time[state_name] = time_us

        # Read Core Temperature & Throttling (once per core)
        core_id = topology[cpu_id]['core_id']
        if core_id != -1 and core_id not in cores_visited_for_temps:
            cores_visited_for_temps.add(core_id)
            therm_stat = read_msr(cpu_id, MSR_IA32_THERM_STATUS)
            temp_val, throttled_val = None, False
            if therm_stat is not None:
                dts = (therm_stat >> 16) & 0x7F
                temp_val = tjmax - dts # Use provided tjmax
                # Check PROCHOT# or Critical Temperature status bits
                throttled_val = bool(therm_stat & 0x01 or therm_stat & 0x02)
            # Apply to all target CPUs belonging to this core
            for c_id in target_cpus:
                 if topology.get(c_id) and topology[c_id]['core_id'] == core_id:
                     cpu_data[c_id].core_temp = temp_val
                     cpu_data[c_id].core_throttled = throttled_val

    return cpu_data, pkg_data


# --- Main Loop ---

def main():
    parser = argparse.ArgumentParser(description="Python Turbostat-like tool using MSR/Sysfs")
    parser.add_argument("-i", "--interval", type=float, default=5.0, help="Measurement interval (sec)")
    parser.add_argument("-c", "--cpu", type=str, default=None, help="CPUs to monitor (comma-separated, ranges allowed, e.g., 0,2,4-7)")
    parser.add_argument("-N", "--header-interval", type=int, default=22, help="Reprint header every N measurement intervals")
    args = parser.parse_args()

    if args.interval <= 0:
        print("Error: Interval must be positive.")
        exit(1)

    # Check for root privileges early if MSR access is needed
    msr_needed = True # Assume MSRs are needed unless proven otherwise
    if os.geteuid() != 0:
        print("Warning: Running without root privileges. MSR access will likely fail.", flush=True)
        # Check if /dev/cpu/0/msr is even readable (crude check)
        try:
            _ = read_msr(0, MSR_IA32_TSC) # Try reading TSC on CPU 0
        except Exception:
             print("         MSR access check failed. MSR-based stats will be unavailable.", flush=True)
             msr_needed = False # Disable MSR reading attempts later


    target_cpus = []
    if args.cpu:
         try:
             cpus_specified = set()
             for part in args.cpu.split(','):
                part = part.strip()
                if '-' in part:
                    start, end = map(int, part.split('-'))
                    cpus_specified.update(range(start, end + 1))
                elif part:
                    cpus_specified.add(int(part))
             # Filter against available CPUs (simple check up to os.cpu_count())
             available_cpus = set(range(os.cpu_count()))
             target_cpus = sorted(list(cpus_specified.intersection(available_cpus)))
             if len(target_cpus) != len(cpus_specified):
                 print(f"Warning: Specified CPUs {cpus_specified - set(target_cpus)} are not available/valid.")
         except ValueError: print(f"Error: Invalid CPU list format: {args.cpu}"); exit(1)
    else: target_cpus = get_effective_cpus()

    if not target_cpus: print("Error: No target CPUs found or specified."); exit(1)

    num_target_cpus = len(target_cpus)
    print(f"Monitoring {num_target_cpus} CPUs: {','.join(map(str, target_cpus))}", flush=True)

    topology = get_cpu_topology(target_cpus)
    # Find the first CPU in the target list that has valid topology info for TjMax reading
    first_cpu_for_tjmax = -1
    for cpu_id in target_cpus:
         if topology.get(cpu_id) and topology[cpu_id]['pkg_id'] != -1:
             first_cpu_for_tjmax = cpu_id
             break
    if first_cpu_for_tjmax == -1:
         if target_cpus: first_cpu_for_tjmax = target_cpus[0] # Fallback to first target CPU
         else: print("Error: Cannot determine a CPU to read TjMax from."); exit(1)

    tjmax = get_tjmax(first_cpu_for_tjmax) if msr_needed else 100 # Default if no MSR access
    rapl_domains_info = find_rapl_domains()
    cpuidle_state_info = {cpu: get_cpuidle_state_info(cpu) for cpu in target_cpus}
    pstate_info = print_pstate_info()

    print(f"Using TjMax: {tjmax}°C (from CPU {first_cpu_for_tjmax})", flush=True)
    if not rapl_domains_info['pkg']: print("Warning: No package RAPL domain found via powercap.", flush=True)
    if not rapl_domains_info['dram']: print("Warning: No DRAM RAPL domain found via powercap.", flush=True)

    # --- Initial Measurement ---
    print("Taking initial measurement...", flush=True)
    prev_cpu_data, prev_pkg_data = get_all_counters(target_cpus, topology, tjmax, rapl_domains_info, cpuidle_state_info, pstate_info)
    if not any(prev_cpu_data.values()): # Check if any data was actually collected
        print("Error: Failed to collect initial counter data. Check permissions and sysfs paths.")
        exit(1)
    # Add a small delay BEFORE the first sleep to ensure counters have changed
    time.sleep(0.1)
    # --------------------------

    iteration = 0
    rows_since_header = 0
    # Calculate max rows based on target CPUs, not total CPUs
    max_rows_before_header = args.header_interval * num_target_cpus if args.header_interval > 0 else float('inf')

    # Define Header - Added POLL%, IPC. Adjusted widths. TAB delimiter.
    # Columns:      Core CPU  ActMHz   Avg_MHz   Busy%   Bzy_MHz   TSC_MHz      IPC         IRQ   POLL%    C1%   C1E%    C6% CoreTmp CoreThr  PkgTmp MinP% MaxP% Governor   EPB PkgWatt RAMWatt
    header_fmt = "{:<4}\t{:<3}\t{:>7}\t{:>7}\t{:>5}\t{:>7}\t{:>7}\t{:>7}\t{:>10}\t{:>5}\t{:>5}\t{:>5}\t{:>5}\t{:>7}\t{:>7}\t{:>7}\t{:>4}\t{:>4}\t{:>11}\t{:>3}\t{:>7}\t{:>7}"
    header_str = header_fmt.format(
        "Core", "CPU", "ActMHz", "AvgMHz", "Busy%", "BzyMHz", "TSCMHz", "IPC", # Added IPC
        "IRQ", "POLL%", "C1%", "C1E%", "C6%", # Example C-states
        "CoreTmp", "CoreThr", "PkgTmp", "MinP%", "MaxP%",
        "Governor", "EPB",
        "PkgWatt", "RAMWatt"
    )

    while True:
        try:
            time.sleep(args.interval) # Sleep first
            current_cpu_data, current_pkg_data = get_all_counters(target_cpus, topology, tjmax, rapl_domains_info, cpuidle_state_info, pstate_info)

            delta_cpu_data = {}
            delta_pkg_data = {}
            valid_delta = True

            for cpu_id in target_cpus:
                # Ensure previous data exists for this CPU
                if cpu_id not in prev_cpu_data:
                    print(f"Warning: Missing previous data for CPU {cpu_id}, skipping delta.")
                    valid_delta = False; break
                delta = current_cpu_data[cpu_id].delta(prev_cpu_data[cpu_id])
                if delta is None:
                    # print(f"Warning: Invalid delta for CPU {cpu_id}, skipping interval.") # Optional debug
                    valid_delta = False; break
                delta_cpu_data[cpu_id] = delta
            if valid_delta:
                 for pkg_id in current_pkg_data:
                      # Ensure previous data exists for this package
                      if pkg_id not in prev_pkg_data:
                          # This might happen if a package appears mid-run (unlikely but possible)
                          print(f"Warning: Missing previous data for Pkg {pkg_id}, skipping delta.")
                          # We might still be able to print CPU data, don't invalidate everything yet
                          # valid_delta = False; break
                          continue # Skip pkg delta calculation for this pkg_id
                      delta = current_pkg_data[pkg_id].delta(prev_pkg_data[pkg_id])
                      if delta is None:
                          print(f"Warning: Invalid delta for Pkg {pkg_id}, skipping interval.")
                          valid_delta = False; break
                      delta_pkg_data[pkg_id] = delta # Store valid package delta

            # Only print if all CPU deltas were valid
            if valid_delta:
                # Print header if needed
                if rows_since_header == 0:
                    utc_now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S %Z') # More standard UTC format
                    print(f"\n--- {utc_now} --- Interval: {args.interval:.2f}s ---", flush=True)
                    print(header_str, flush=True)

                for cpu_id in target_cpus:
                    # CPU delta must exist if valid_delta is True
                    delta = delta_cpu_data[cpu_id]
                    interval_sec = delta.timestamp # Use the calculated delta time
                    core_id_val = topology[cpu_id]['core_id']
                    pkg_id = topology[cpu_id]['pkg_id']

                    # --- Calculations (ensure denominators > 0) ---
                    avg_mhz = delta.aperf / interval_sec / 1_000_000 if interval_sec > 0 else 0.0
                    busy_pct = 100.0 * delta.mperf / delta.tsc if delta.tsc > 0 else 0.0
                    tsc_mhz = delta.tsc / interval_sec / 1_000_000 if interval_sec > 0 else 0.0
                    # Bzy_MHz: Use AvgMHz if Busy% > 0, else 0. Avoids div by zero if mperf is 0.
                    bzy_mhz = avg_mhz / (busy_pct / 100.0) if busy_pct > 0.01 else 0.0 # Use AvgMHz / busy_fraction

                    # **** Calculate IPC using Instructions / APERF ****
                    ipc = delta.instr_retired / delta.aperf if delta.aperf > 0 else 0.0

                    # C-State Percentages
                    interval_us = interval_sec * 1_000_000
                    # Get delta time for specific states (handle missing states gracefully)
                    poll_time_delta = delta.cstate_time.get('POLL', 0)
                    c1_time_delta = delta.cstate_time.get('C1', 0)
                    c1e_time_delta = delta.cstate_time.get('C1E', 0)
                    c6_time_delta = delta.cstate_time.get('C6', 0) # Example states

                    # Calculate percentages, clamp to 100%
                    poll_pct = min(100.0, 100.0 * poll_time_delta / interval_us) if interval_us > 0 else 0.0
                    c1_pct = min(100.0, 100.0 * c1_time_delta / interval_us) if interval_us > 0 else 0.0
                    c1e_pct = min(100.0, 100.0 * c1e_time_delta / interval_us) if interval_us > 0 else 0.0
                    c6_pct = min(100.0, 100.0 * c6_time_delta / interval_us) if interval_us > 0 else 0.0

                    # Package Watts (check if delta_pkg_data exists for this pkg_id)
                    d_pkg = delta_pkg_data.get(pkg_id)
                    pkg_watt_val = (d_pkg.energy_pkg_uj / 1_000_000) / interval_sec if d_pkg and interval_sec > 0 else 0.0
                    ram_watt_val = (d_pkg.energy_dram_uj / 1_000_000) / interval_sec if d_pkg and interval_sec > 0 else 0.0

                    # --- Formatting Data Row ---
                    print(header_fmt.format(
                        str(core_id_val) if core_id_val != -1 else "-",        # Core
                        cpu_id,                                                # CPU
                        f"{delta.actual_mhz:.1f}" if delta.actual_mhz is not None else "-", # ActMHz
                        f"{avg_mhz:.1f}",                                     # AvgMHz
                        f"{busy_pct:.2f}",                                   # Busy%
                        f"{bzy_mhz:.1f}",                                     # BzyMHz
                        f"{tsc_mhz:.1f}",                                     # TSCMHz
                        f"{ipc:.2f}",                                         # << IPC >>
                        delta.irq_count if delta.irq_count is not None else "-", # IRQ
                        f"{poll_pct:.2f}",                                   # POLL%
                        f"{c1_pct:.2f}",                                     # C1%
                        f"{c1e_pct:.2f}",                                    # C1E%
                        f"{c6_pct:.2f}",                                     # C6%
                        str(delta.core_temp) if delta.core_temp is not None else "-", # CoreTmp
                        "Y" if delta.core_throttled else "N",                   # CoreThr
                        str(d_pkg.pkg_temp) if d_pkg and d_pkg.pkg_temp is not None else "-", # PkgTmp
                        str(delta.min_perf_pct) if delta.min_perf_pct is not None else "-", # MinP%
                        str(delta.max_perf_pct) if delta.max_perf_pct is not None else "-", # MaxP%
                        str(delta.governor)[:11] if delta.governor else "-",    # Governor (limit length)
                        str(delta.epb) if delta.epb is not None else "-",       # EPB
                        f"{pkg_watt_val:.2f}",                               # PkgWatt
                        f"{ram_watt_val:.2f}"                                # RAMWatt
                    ), flush=True)
                    rows_since_header += 1

                # Reset header counter if max rows reached
                if rows_since_header >= max_rows_before_header:
                    rows_since_header = 0
            # else: # Already printed a warning if delta was invalid
            #    pass

            # Update previous data state for the next iteration
            prev_cpu_data = current_cpu_data
            prev_pkg_data = current_pkg_data
            iteration += 1


        except KeyboardInterrupt:
            print("\nExiting.")
            break
        except Exception as e:
            print(f"\nRuntime error on iteration {iteration}: {e}", flush=True)
            import traceback
            traceback.print_exc()
            # Optional: Decide whether to try continuing or exit on error
            # time.sleep(args.interval) # Wait before potentially retrying

if __name__ == "__main__":
    main()
