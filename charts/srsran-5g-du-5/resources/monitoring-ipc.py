#!/usr/bin/env python3

import os
import time
import argparse
import re
import struct
import glob
import sys # For exit
from collections import defaultdict
from datetime import datetime, timezone

# --- MSR Addresses ---
MSR_IA32_TSC = 0x10
MSR_IA32_MPERF = 0xE7
MSR_IA32_APERF = 0xE8
MSR_IA32_THERM_STATUS = 0x19C
MSR_IA32_PACKAGE_THERM_STATUS = 0x1B1
MSR_IA32_TEMPERATURE_TARGET = 0x1A2
# Fixed-Function Performance Counters
MSR_IA32_FIXED_CTR0 = 0x309 # Instructions Retired
# Performance Counter Control MSRs
MSR_IA32_FIXED_CTR_CTRL = 0x38D
MSR_IA32_PERF_GLOBAL_CTRL = 0x38F

# --- Constants ---
MAX_CPUIDLE_STATES = 10
PSTATE_BASE_PATH = "/sys/devices/system/cpu/intel_pstate"
FIXED_CTR0_ENABLE_BIT = 1 << 32 # Bit 32 for MSR_IA32_PERF_GLOBAL_CTRL
FIXED_CTR0_CONFIG_MASK = 0xF # Bits 0-3 for MSR_IA32_FIXED_CTR_CTRL
FIXED_CTR0_CONFIG_VAL = 0x3 # Enable OS+USR counting for CTR0

# --- Helper Functions ---
# (read_sysfs_int, read_sysfs_str remain the same)
def read_sysfs_int(path):
    try:
        with open(path, 'r') as f:
            return int(f.read().strip())
    except Exception:
        return None

def read_sysfs_str(path):
    try:
        with open(path, 'r') as f:
            return f.read().strip()
    except Exception:
        return None

def read_msr(cpu_id, reg):
    """Reads a 64-bit MSR value for a specific CPU."""
    try:
        with open(f'/dev/cpu/{cpu_id}/msr', 'rb') as f:
            f.seek(reg)
            msr_val_bytes = f.read(8)
            if len(msr_val_bytes) == 8:
                return struct.unpack('<Q', msr_val_bytes)[0]
            else:
                print(f"Warning: Short read from MSR {hex(reg)} on CPU {cpu_id}", file=sys.stderr)
                return None
    except OSError as e:
        # Only print error if it's not 'No such file or directory' (msr module not loaded?)
        # or 'Permission denied' (handled later)
        if e.errno != 2 and e.errno != 13 :
             print(f"Warning: Cannot read MSR {hex(reg)} on CPU {cpu_id}: {e}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Error: Unexpected error reading MSR {hex(reg)} on CPU {cpu_id}: {e}", file=sys.stderr)
        return None

def write_msr(cpu_id, reg, value):
    """Writes a 64-bit value to a specific MSR for a specific CPU."""
    try:
        value_bytes = struct.pack('<Q', value) # Pack value into 8 bytes (Little-endian Unsigned Long Long)
        with open(f'/dev/cpu/{cpu_id}/msr', 'wb') as f: # Open in binary write mode
            f.seek(reg)
            bytes_written = f.write(value_bytes)
            if bytes_written == 8:
                return True
            else:
                print(f"Warning: Short write to MSR {hex(reg)} on CPU {cpu_id} ({bytes_written}/8 bytes)", file=sys.stderr)
                return False
    except OSError as e:
        print(f"Error: Cannot write MSR {hex(reg)} on CPU {cpu_id}: {e}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Error: Unexpected error writing MSR {hex(reg)} on CPU {cpu_id}: {e}", file=sys.stderr)
        return False

def enable_fixed_counter0(target_cpus):
    """Enables FIXED_CTR0 on target CPUs using Read-Modify-Write."""
    print("Attempting to enable FIXED_CTR0 (Instructions Retired) via MSR...")
    success_all = True
    for cpu_id in target_cpus:
        # 1. Configure FIXED_CTR_CTRL (0x38D)
        current_ctrl = read_msr(cpu_id, MSR_IA32_FIXED_CTR_CTRL)
        if current_ctrl is None:
            print(f"  CPU {cpu_id}: Failed to read FIXED_CTR_CTRL (0x38D). Skipping enable.", file=sys.stderr)
            success_all = False
            continue

        # Clear existing CTR0 config (bits 0-3) and set new config (0x3)
        new_ctrl = (current_ctrl & ~FIXED_CTR0_CONFIG_MASK) | FIXED_CTR0_CONFIG_VAL
        if not write_msr(cpu_id, MSR_IA32_FIXED_CTR_CTRL, new_ctrl):
            print(f"  CPU {cpu_id}: Failed to write FIXED_CTR_CTRL (0x38D).", file=sys.stderr)
            success_all = False
            continue # Don't try global enable if config failed

        # 2. Globally enable FIXED_CTR0 in PERF_GLOBAL_CTRL (0x38F)
        current_global_ctrl = read_msr(cpu_id, MSR_IA32_PERF_GLOBAL_CTRL)
        if current_global_ctrl is None:
            print(f"  CPU {cpu_id}: Failed to read PERF_GLOBAL_CTRL (0x38F). Skipping enable.", file=sys.stderr)
            success_all = False
            # Optional: Attempt to revert the config change? Might be complex.
            continue

        # Set the enable bit for CTR0 (bit 32)
        new_global_ctrl = current_global_ctrl | FIXED_CTR0_ENABLE_BIT
        if not write_msr(cpu_id, MSR_IA32_PERF_GLOBAL_CTRL, new_global_ctrl):
            print(f"  CPU {cpu_id}: Failed to write PERF_GLOBAL_CTRL (0x38F).", file=sys.stderr)
            success_all = False
            continue

        # print(f"  CPU {cpu_id}: FIXED_CTR0 configured and globally enabled.") # Optional success message per CPU

    if success_all:
        print("FIXED_CTR0 enable attempted successfully on all target CPUs.")
    else:
        print("Warning: Failed to enable FIXED_CTR0 on one or more CPUs. IPC will likely be 0.", file=sys.stderr)
    return success_all

def disable_fixed_counter0(target_cpus):
    """Disables FIXED_CTR0 globally on target CPUs using Read-Modify-Write."""
    print("\nAttempting to disable FIXED_CTR0 globally...")
    success_all = True
    for cpu_id in target_cpus:
        current_global_ctrl = read_msr(cpu_id, MSR_IA32_PERF_GLOBAL_CTRL)
        if current_global_ctrl is None:
            # Don't treat read failure here as critical, maybe it was never enabled
            # print(f"  CPU {cpu_id}: Failed to read PERF_GLOBAL_CTRL (0x38F) during disable.", file=sys.stderr)
            continue # Try next CPU

        # Clear the enable bit for CTR0 (bit 32)
        new_global_ctrl = current_global_ctrl & ~FIXED_CTR0_ENABLE_BIT
        if new_global_ctrl != current_global_ctrl: # Only write if changed
             if not write_msr(cpu_id, MSR_IA32_PERF_GLOBAL_CTRL, new_global_ctrl):
                 print(f"  CPU {cpu_id}: Failed to write PERF_GLOBAL_CTRL (0x38F) during disable.", file=sys.stderr)
                 success_all = False
             # else: # Optional success message
             #    print(f"  CPU {cpu_id}: FIXED_CTR0 globally disabled.")

    # We don't necessarily need to clear the config in 0x38D,
    # as the global disable in 0x38F stops counting.
    if success_all:
        print("FIXED_CTR0 global disable attempted.")
    else:
        print("Warning: Failed to globally disable FIXED_CTR0 on one or more CPUs.", file=sys.stderr)
    return success_all


# (parse_interrupts, get_cpu_topology, get_tjmax, find_rapl_domains, get_cpuidle_state_info, get_effective_cpus, print_pstate_info remain the same)
def parse_interrupts():
    irq_counts = defaultdict(int); cpu_columns = {}
    try:
        with open('/proc/interrupts', 'r') as f: lines = f.readlines()
        if not lines: return irq_counts
        header = lines[0].split()
        cpu_pattern = re.compile(r'^CPU(\d+)$')
        for idx, col_name in enumerate(header):
            match = cpu_pattern.match(col_name)
            if match:
                cpu_columns[idx] = int(match.group(1))
        if not cpu_columns: return irq_counts
        for line in lines[1:]:
            parts = line.split()
            if not parts or not (parts[0].endswith(':') or re.match(r'^[A-Za-z0-9]', parts[0])): continue
            count_start_col = 1
            while count_start_col < len(parts) and not parts[count_start_col].isdigit():
                 count_start_col += 1
            header_indices = sorted(cpu_columns.keys())
            part_indices = {}
            if len(header_indices) > 0:
                base_part_idx = count_start_col
                for i, h_idx in enumerate(header_indices):
                    part_indices[h_idx] = base_part_idx + i
            for header_idx, cpu_id in cpu_columns.items():
                part_idx = part_indices.get(header_idx)
                if part_idx is not None and part_idx < len(parts):
                    try: irq_counts[cpu_id] += int(parts[part_idx])
                    except (ValueError, IndexError): continue
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
        for path in glob.glob(os.path.join(powercap_base, "intel-rapl:?")):
            if os.path.isdir(path) and ':' not in os.path.basename(path).split(':')[-1]:
                name = read_sysfs_str(os.path.join(path, "name"))
                energy_path = os.path.join(path, "energy_uj")
                max_energy_path = os.path.join(path, "max_energy_range_uj")
                if name and name.startswith("package") and os.path.exists(energy_path) and os.path.exists(max_energy_path):
                    try:
                        id_str = os.path.basename(path).split(':')[-1]
                        id_ = int(id_str)
                        domains['pkg'].append({'id': id_, 'path': energy_path, 'max_path': max_energy_path})
                    except ValueError:
                         domains['pkg'].append({'id': -1, 'path': energy_path, 'max_path': max_energy_path})
        for path in glob.glob(os.path.join(powercap_base, "intel-rapl:??*")):
            if os.path.isdir(path) and ':' not in os.path.basename(path).split(':')[-1]:
                 name = read_sysfs_str(os.path.join(path, "name"))
                 energy_path = os.path.join(path, "energy_uj")
                 max_energy_path = os.path.join(path, "max_energy_range_uj")
                 if name and name.startswith("package") and os.path.exists(energy_path) and os.path.exists(max_energy_path):
                     try:
                         id_str = os.path.basename(path).split(':')[-1]
                         id_ = int(id_str)
                         if not any(d['id'] == id_ for d in domains['pkg']):
                              domains['pkg'].append({'id': id_, 'path': energy_path, 'max_path': max_energy_path})
                     except ValueError: pass
        for path in glob.glob(os.path.join(powercap_base, "intel-rapl:*:?")):
             if os.path.isdir(path):
                 name = read_sysfs_str(os.path.join(path, "name"))
                 energy_path = os.path.join(path, "energy_uj")
                 max_energy_path = os.path.join(path, "max_energy_range_uj")
                 if name == "dram" and os.path.exists(energy_path) and os.path.exists(max_energy_path):
                     try:
                         parent_basename = os.path.basename(os.path.dirname(path))
                         pkg_id_str = parent_basename.split(':')[-1]
                         pkg_id_ = int(pkg_id_str)
                         domains['dram'].append({'id': pkg_id_, 'path': energy_path, 'max_path': max_energy_path})
                     except (ValueError, IndexError):
                          domains['dram'].append({'id': -1, 'path': energy_path, 'max_path': max_energy_path})
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
                        if not any(d['id'] == pkg_id_ for d in domains['dram']):
                            domains['dram'].append({'id': pkg_id_, 'path': energy_path, 'max_path': max_energy_path})
                    except (ValueError, IndexError): pass
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
            if not os.path.isdir(state_dir) or not os.path.exists(name_path) or not os.path.exists(time_path): continue
            name = read_sysfs_str(name_path)
            if name: state_info[name] = {'time': time_path}
    except Exception as e: print(f"Warning: Error probing cpuidle for CPU {cpu_id}: {e}")
    return state_info

def get_effective_cpus():
    paths_to_try = [
        '/sys/fs/cgroup/cpuset.cpus.effective',
        '/sys/fs/cgroup/cpuset/cpuset.effective_cpus'
    ]
    cpu_str = None; path_read = None
    for path in paths_to_try:
        if os.path.exists(path):
            path_read = path
            try:
                with open(path, 'r') as f: cpu_str = f.read().strip()
                if cpu_str: break
            except Exception as e: print(f"Warning: Could not read {path}: {e}.")
    if cpu_str is None or cpu_str == "":
        try: return sorted(list(os.sched_getaffinity(0)))
        except OSError: print("Error: Cannot get process affinity."); return []
        except AttributeError: print("Error: os.sched_getaffinity not available on this platform."); return list(range(os.cpu_count()))
    cpus = set()
    for part in cpu_str.split(','):
        try:
            part = part.strip()
            if '-' in part:
                start, end = map(int, part.split('-'))
                cpus.update(range(start, end + 1))
            elif part:
                cpus.add(int(part))
        except ValueError: print(f"Warning: Could not parse CPU part '{part}' in effective CPU string '{cpu_str}' from {path_read}")
    return sorted(list(cpus))

def print_pstate_info():
    info = {'min_perf_pct_path': None, 'max_perf_pct_path': None, 'status': None, 'no_turbo': None, 'hwp_boost': None}
    if not os.path.exists(PSTATE_BASE_PATH):
        print("intel_pstate sysfs directory not found.")
        return info
    info['status'] = read_sysfs_str(os.path.join(PSTATE_BASE_PATH, "status"))
    info['no_turbo'] = read_sysfs_int(os.path.join(PSTATE_BASE_PATH, "no_turbo"))
    info['hwp_boost'] = read_sysfs_int(os.path.join(PSTATE_BASE_PATH, "hwp_dynamic_boost"))
    # info['min_perf_pct_path'] = os.path.join(PSTATE_BASE_PATH, "min_perf_pct")
    # info['max_perf_pct_path'] = os.path.join(PSTATE_BASE_PATH, "max_perf_pct")
    print("--- Intel P-State Info ---", flush=True)
    print(f" Status:\t{info['status'] if info['status'] is not None else 'N/A'}", flush=True)
    print(f" No Turbo:\t{info['no_turbo'] if info['no_turbo'] is not None else 'N/A'} (1=disabled, 0=enabled)", flush=True)
    print(f" HWP Boost:\t{info['hwp_boost'] if info['hwp_boost'] is not None else 'N/A'} (1=enabled, 0=disabled)", flush=True)
    print("--------------------------", flush=True)
    return info

# --- Data Structures ---
# (CPUData, PkgData, calculate_delta_energy remain the same)
class CPUData:
    def __init__(self):
        self.timestamp = 0.0
        self.tsc = 0
        self.aperf = 0
        self.mperf = 0
        self.instr_retired = 0
        self.irq_count = 0
        self.core_temp = None
        self.core_throttled = False
        self.actual_mhz = None
        self.governor = None
        self.epb = None
        # self.min_perf_pct = None
        # self.max_perf_pct = None
        self.scaling_min_mhz = None
        self.scaling_max_mhz = None
        self.cstate_time = defaultdict(int)

    def delta(self, prev):
        if not isinstance(prev, CPUData) or self.timestamp <= prev.timestamp:
             if self.timestamp == prev.timestamp and self.tsc == prev.tsc: pass
             else: return None
        if self.tsc < prev.tsc: return None
        d = CPUData(); d.timestamp = self.timestamp - prev.timestamp
        if d.timestamp <= 0: d.timestamp = 1e-9
        d.tsc = self.tsc - prev.tsc
        d.aperf = self.aperf - prev.aperf if self.aperf >= prev.aperf else (2**64 - prev.aperf) + self.aperf
        d.mperf = self.mperf - prev.mperf if self.mperf >= prev.mperf else (2**64 - prev.mperf) + self.mperf
        d.instr_retired = self.instr_retired - prev.instr_retired if self.instr_retired >= prev.instr_retired else (2**64 - prev.instr_retired) + self.instr_retired
        d.irq_count = self.irq_count - prev.irq_count
        d.core_temp = self.core_temp
        d.core_throttled = self.core_throttled
        d.actual_mhz = self.actual_mhz
        d.governor = self.governor
        d.epb = self.epb
        d.scaling_min_mhz = self.scaling_min_mhz
        d.scaling_max_mhz = self.scaling_max_mhz
        # d.min_perf_pct = self.min_perf_pct
        # d.max_perf_pct = self.max_perf_pct
        for name, time_now in self.cstate_time.items():
            time_prev = prev.cstate_time.get(name, 0)
            d.cstate_time[name] = time_now - time_prev if time_now >= time_prev else (2**64 - time_prev) + time_now
        return d

def calculate_delta_energy(current_uj, prev_uj, max_range_uj):
    if max_range_uj is None or max_range_uj <= 0: max_range_uj = 2**63
    if current_uj >= prev_uj: delta = current_uj - prev_uj
    else: delta = (max_range_uj - prev_uj) + current_uj
    if delta > max_range_uj: return 0
    return delta

class PkgData:
     def __init__(self):
        self.timestamp = 0.0
        self.pkg_temp = None
        self.energy_pkg_uj = 0
        self.energy_dram_uj = 0
        self.max_energy_pkg_uj = 0
        self.max_energy_dram_uj = 0

     def delta(self, prev):
        if not isinstance(prev, PkgData) or self.timestamp <= prev.timestamp: return None
        d = PkgData(); d.timestamp = self.timestamp - prev.timestamp
        if d.timestamp <= 0: d.timestamp = 1e-9
        d.pkg_temp = self.pkg_temp
        d.energy_pkg_uj = calculate_delta_energy(self.energy_pkg_uj, prev.energy_pkg_uj, self.max_energy_pkg_uj)
        d.energy_dram_uj = calculate_delta_energy(self.energy_dram_uj, prev.energy_dram_uj, self.max_energy_dram_uj)
        d.max_energy_pkg_uj = self.max_energy_pkg_uj
        d.max_energy_dram_uj = self.max_energy_dram_uj
        return d


# --- Data Collection ---
# (get_all_counters remains largely the same, reads MSR 0x309)
def get_all_counters(target_cpus, topology, tjmax, rapl_domains_info, cpuidle_state_info, pstate_paths):
    current_irqs = parse_interrupts()
    timestamp = time.monotonic()
    cpu_data = {cpu: CPUData() for cpu in target_cpus}
    all_pkg_ids = {info['pkg_id'] for cpu_id, info in topology.items()
                   if cpu_id in target_cpus and info['pkg_id'] != -1}
    pkg_data = {pkg_id: PkgData() for pkg_id in all_pkg_ids}
    # min_perf = read_sysfs_int(pstate_paths.get('min_perf_pct_path'))
    # max_perf = read_sysfs_int(pstate_paths.get('max_perf_pct_path'))
    pkgs_visited_for_temps = set()
    pkgs_visited_for_rapl = set()
    for pkg_id in all_pkg_ids:
        rep_cpu = -1
        for c_id in target_cpus:
            if topology.get(c_id) and topology[c_id]['pkg_id'] == pkg_id:
                rep_cpu = c_id; break
        if rep_cpu == -1: continue
        p_data = pkg_data[pkg_id]; p_data.timestamp = timestamp
        if pkg_id not in pkgs_visited_for_temps:
            pkg_therm_stat = read_msr(rep_cpu, MSR_IA32_PACKAGE_THERM_STATUS)
            if pkg_therm_stat is not None:
                p_data.pkg_temp = tjmax - ((pkg_therm_stat >> 16) & 0x7F)
            pkgs_visited_for_temps.add(pkg_id)
        if pkg_id not in pkgs_visited_for_rapl:
            pkg_rapl_info, dram_rapl_info = None, None
            for domain in rapl_domains_info.get('pkg', []):
                 if domain['id'] == pkg_id: pkg_rapl_info = domain; break
            if not pkg_rapl_info and len(rapl_domains_info.get('pkg', [])) == 1 and rapl_domains_info['pkg'][0]['id'] == -1:
                 if len(all_pkg_ids) == 1: pkg_rapl_info = rapl_domains_info['pkg'][0]
            for domain in rapl_domains_info.get('dram', []):
                 if domain['id'] == pkg_id: dram_rapl_info = domain; break
            if not dram_rapl_info and len(rapl_domains_info.get('dram', [])) == 1 and rapl_domains_info['dram'][0]['id'] == -1:
                 if len(all_pkg_ids) == 1 or pkg_id == 0: dram_rapl_info = rapl_domains_info['dram'][0]
            if pkg_rapl_info:
                p_data.max_energy_pkg_uj = read_sysfs_int(pkg_rapl_info['max_path'])
                p_data.energy_pkg_uj = read_sysfs_int(pkg_rapl_info['path']) or 0
            if dram_rapl_info:
                p_data.max_energy_dram_uj = read_sysfs_int(dram_rapl_info['max_path'])
                p_data.energy_dram_uj = read_sysfs_int(dram_rapl_info['path']) or 0
            pkgs_visited_for_rapl.add(pkg_id)
    cores_visited_for_temps = set()
    for cpu_id in target_cpus:
        data = cpu_data[cpu_id]; data.timestamp = timestamp
        data.tsc = read_msr(cpu_id, MSR_IA32_TSC) or 0
        data.aperf = read_msr(cpu_id, MSR_IA32_APERF) or 0
        data.mperf = read_msr(cpu_id, MSR_IA32_MPERF) or 0
        data.instr_retired = read_msr(cpu_id, MSR_IA32_FIXED_CTR0) or 0 # Read Inst Retired MSR
        data.irq_count = current_irqs.get(cpu_id, 0)
        act_mhz_khz = read_sysfs_int(f'/sys/devices/system/cpu/cpu{cpu_id}/cpufreq/scaling_cur_freq')
        data.actual_mhz = act_mhz_khz / 1000 if act_mhz_khz is not None else None
        data.governor = read_sysfs_str(f'/sys/devices/system/cpu/cpu{cpu_id}/cpufreq/scaling_governor')
        data.epb = read_sysfs_int(f'/sys/devices/system/cpu/cpu{cpu_id}/power/energy_perf_bias')
        min_freq_khz = read_sysfs_int(f'/sys/devices/system/cpu/cpu{cpu_id}/cpufreq/scaling_min_freq')
        max_freq_khz = read_sysfs_int(f'/sys/devices/system/cpu/cpu{cpu_id}/cpufreq/scaling_max_freq')
        data.scaling_min_mhz = min_freq_khz / 1000 if min_freq_khz is not None else None
        data.scaling_max_mhz = max_freq_khz / 1000 if max_freq_khz is not None else None
        # data.min_perf_pct = min_perf; data.max_perf_pct = max_perf
        if cpu_id in cpuidle_state_info:
            for state_name, paths in cpuidle_state_info[cpu_id].items():
                 time_us = read_sysfs_int(paths['time'])
                 if time_us is not None: data.cstate_time[state_name] = time_us
        core_id = topology[cpu_id]['core_id']
        if core_id != -1 and core_id not in cores_visited_for_temps:
            cores_visited_for_temps.add(core_id)
            therm_stat = read_msr(cpu_id, MSR_IA32_THERM_STATUS)
            temp_val, throttled_val = None, False
            if therm_stat is not None:
                temp_val = tjmax - ((therm_stat >> 16) & 0x7F)
                throttled_val = bool(therm_stat & 0x01 or therm_stat & 0x02)
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
        print("Error: Interval must be positive.", file=sys.stderr)
        exit(1)

    is_root = os.geteuid() == 0
    msr_module_loaded = os.path.exists('/dev/cpu/0/msr') # Basic check

    if not is_root:
        print("Warning: Running without root privileges.", file=sys.stderr)
        print("         MSR access (needed for TSC, APERF, MPERF, Temps, InstrRetired) will fail.", file=sys.stderr)
        print("         IPC and other MSR-based stats will be unavailable or zero.", file=sys.stderr)
    elif not msr_module_loaded:
         print("Warning: 'msr' kernel module not loaded or /dev/cpu/0/msr not found.", file=sys.stderr)
         print("         MSR access will fail. Load the module (sudo modprobe msr).", file=sys.stderr)
         is_root = False # Treat as non-root if module isn't loaded


    target_cpus = []
    # (CPU parsing remains the same as previous version)
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
             available_cpus = set(range(os.cpu_count()))
             target_cpus = sorted(list(cpus_specified.intersection(available_cpus)))
             if len(target_cpus) != len(cpus_specified):
                 print(f"Warning: Specified CPUs {cpus_specified - set(target_cpus)} are not available/valid.", file=sys.stderr)
         except ValueError: print(f"Error: Invalid CPU list format: {args.cpu}", file=sys.stderr); exit(1)
    else: target_cpus = get_effective_cpus()

    if not target_cpus: print("Error: No target CPUs found or specified.", file=sys.stderr); exit(1)

    num_target_cpus = len(target_cpus)
    print(f"Monitoring {num_target_cpus} CPUs: {','.join(map(str, target_cpus))}", flush=True)

    topology = get_cpu_topology(target_cpus)
    first_cpu_for_tjmax = target_cpus[0] # Default, find better one below
    for cpu_id in target_cpus:
         if topology.get(cpu_id) and topology[cpu_id]['pkg_id'] != -1:
             first_cpu_for_tjmax = cpu_id; break

    tjmax = get_tjmax(first_cpu_for_tjmax) if is_root else 100 # Use default if not root
    rapl_domains_info = find_rapl_domains()
    cpuidle_state_info = {cpu: get_cpuidle_state_info(cpu) for cpu in target_cpus}
    pstate_info = print_pstate_info()

    print(f"Using TjMax: {tjmax}°C (from CPU {first_cpu_for_tjmax})", flush=True)
    if not rapl_domains_info['pkg']: print("Warning: No package RAPL domain found via powercap.", flush=True)
    if not rapl_domains_info['dram']: print("Warning: No DRAM RAPL domain found via powercap.", flush=True)

    # --- Attempt to enable counters if root ---
    counters_enabled_by_script = False
    if is_root:
        counters_enabled_by_script = enable_fixed_counter0(target_cpus)
        if not counters_enabled_by_script:
            print("Warning: Proceeding despite counter enable failure. IPC may be 0.", file=sys.stderr)
    else:
         print("Info: Cannot enable counters without root. Relying on external enablement for IPC.", flush=True)


    # --- Initial Measurement ---
    print("Taking initial measurement...", flush=True)
    prev_cpu_data, prev_pkg_data = get_all_counters(target_cpus, topology, tjmax, rapl_domains_info, cpuidle_state_info, pstate_info)
    if not any(prev_cpu_data.values()):
        print("Error: Failed to collect initial counter data. Check permissions and sysfs paths.", file=sys.stderr)
        if is_root and counters_enabled_by_script: disable_fixed_counter0(target_cpus) # Clean up if we enabled
        exit(1)

    # Check if initial reads worked
    first_cpu_data = prev_cpu_data.get(target_cpus[0])
    if is_root and first_cpu_data and first_cpu_data.tsc == 0:
         print("Warning: Initial MSR reads returned 0 despite root. Check msr module and hardware. Stats may be inaccurate.", file=sys.stderr)


    time.sleep(0.1)

    # --- Header Setup ---
    # (Header format and string remain the same)
    header_fmt = "{:<4}\t{:<3}\t{:>7}\t{:>7}\t{:>5}\t{:>7}\t{:>7}\t{:>7}\t{:>10}\t{:>5}\t{:>5}\t{:>5}\t{:>5}\t{:>7}\t{:>7}\t{:>7}\t{:>4}\t{:>4}\t{:>11}\t{:>3}\t{:>7}\t{:>7}"
    header_str = header_fmt.format(
        "Core", "CPU", "ActMHz", "Avg_MHz", "Busy%", "Bzy_MHz", "TSC_MHz", "IPC",
        "IRQ", "POLL%", "C1%", "C1E%", "C6%",
        # "CoreTmp", "CoreThr", "PkgTmp", "MinP%", "MaxP%",
        "CoreTmp", "CoreThr", "PkgTmp", "MinMHz", "MaxMHz",       
        "Governor", "EPB",
        "PkgWatt", "RAMWatt"
    )

    iteration = 0
    rows_since_header = 0
    max_rows_before_header = args.header_interval * num_target_cpus if args.header_interval > 0 else float('inf')

    try: # Main loop wrapped in try for finally cleanup
        while True:
            time.sleep(args.interval)
            current_cpu_data, current_pkg_data = get_all_counters(target_cpus, topology, tjmax, rapl_domains_info, cpuidle_state_info, pstate_info)

            delta_cpu_data = {}
            delta_pkg_data = {}
            valid_delta = True

            # (Delta calculation loop remains the same)
            for cpu_id in target_cpus:
                if cpu_id not in prev_cpu_data: valid_delta = False; break
                delta = current_cpu_data[cpu_id].delta(prev_cpu_data[cpu_id])
                if delta is None: valid_delta = False; break
                delta_cpu_data[cpu_id] = delta
            if valid_delta:
                 for pkg_id in current_pkg_data:
                      if pkg_id not in prev_pkg_data: continue
                      delta = current_pkg_data[pkg_id].delta(prev_pkg_data[pkg_id])
                      if delta is None: valid_delta = False; break
                      delta_pkg_data[pkg_id] = delta

            if valid_delta:
                if rows_since_header == 0:
                    utc_now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S %Z')
                    print(f"\n--- {utc_now} ---", flush=True)
                    print(header_str, flush=True)

                # (Printing loop remains the same, IPC calculation is correct)
                for cpu_id in target_cpus:
                    delta = delta_cpu_data[cpu_id]
                    interval_sec = delta.timestamp
                    core_id_val = topology[cpu_id]['core_id']
                    pkg_id = topology[cpu_id]['pkg_id']
                    avg_mhz = delta.aperf / interval_sec / 1_000_000 if interval_sec > 0 else 0.0
                    busy_pct = 100.0 * delta.mperf / delta.tsc if delta.tsc > 0 else 0.0
                    tsc_mhz = delta.tsc / interval_sec / 1_000_000 if interval_sec > 0 else 0.0
                    bzy_mhz = avg_mhz / (busy_pct / 100.0) if busy_pct > 0.01 else 0.0
                    ipc = delta.instr_retired / delta.aperf if delta.aperf > 0 else 0.0 # Correct IPC calc
                    interval_us = interval_sec * 1_000_000
                    poll_time_delta = delta.cstate_time.get('POLL', 0)
                    c1_time_delta = delta.cstate_time.get('C1', 0)
                    c1e_time_delta = delta.cstate_time.get('C1E', 0)
                    c6_time_delta = delta.cstate_time.get('C6', 0)
                    poll_pct = min(100.0, 100.0 * poll_time_delta / interval_us) if interval_us > 0 else 0.0
                    c1_pct = min(100.0, 100.0 * c1_time_delta / interval_us) if interval_us > 0 else 0.0
                    c1e_pct = min(100.0, 100.0 * c1e_time_delta / interval_us) if interval_us > 0 else 0.0
                    c6_pct = min(100.0, 100.0 * c6_time_delta / interval_us) if interval_us > 0 else 0.0
                    d_pkg = delta_pkg_data.get(pkg_id)
                    pkg_watt_val = (d_pkg.energy_pkg_uj / 1_000_000) / interval_sec if d_pkg and interval_sec > 0 else 0.0
                    ram_watt_val = (d_pkg.energy_dram_uj / 1_000_000) / interval_sec if d_pkg and interval_sec > 0 else 0.0
                    print(header_fmt.format(
                        str(core_id_val) if core_id_val != -1 else "-", cpu_id,
                        f"{delta.actual_mhz:.1f}" if delta.actual_mhz is not None else "-",
                        f"{avg_mhz:.1f}", f"{busy_pct:.2f}", f"{bzy_mhz:.1f}", f"{tsc_mhz:.1f}", f"{ipc:.2f}",
                        delta.irq_count if delta.irq_count is not None else "-",
                        f"{poll_pct:.2f}", f"{c1_pct:.2f}", f"{c1e_pct:.2f}", f"{c6_pct:.2f}",
                        str(delta.core_temp) if delta.core_temp is not None else "-",
                        "Y" if delta.core_throttled else "N",
                        str(d_pkg.pkg_temp) if d_pkg and d_pkg.pkg_temp is not None else "-",
                        # str(delta.min_perf_pct) if delta.min_perf_pct is not None else "-",
                        # str(delta.max_perf_pct) if delta.max_perf_pct is not None else "-",
                        f"{delta.scaling_min_mhz:.0f}" if delta.scaling_min_mhz is not None else "", # MinMHz
                        f"{delta.scaling_max_mhz:.0f}" if delta.scaling_max_mhz is not None else "", # MaxMHz
                        str(delta.governor)[:11] if delta.governor else "-",
                        str(delta.epb) if delta.epb is not None else "-",
                        f"{pkg_watt_val:.2f}", f"{ram_watt_val:.2f}"
                    ), flush=True)
                    rows_since_header += 1
                if rows_since_header >= max_rows_before_header:
                    rows_since_header = 0

            prev_cpu_data = current_cpu_data
            prev_pkg_data = current_pkg_data
            iteration += 1

    except KeyboardInterrupt:
        print("\nExiting.")
    except Exception as e:
        print(f"\nRuntime error on iteration {iteration}: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
    finally:
        # --- Cleanup: Disable counter if we enabled it ---
        if is_root and counters_enabled_by_script:
            disable_fixed_counter0(target_cpus)


if __name__ == "__main__":
    # Basic check for msr module before starting
    if not os.path.exists('/dev/cpu/0/msr') and os.geteuid() == 0:
         print("Error: /dev/cpu/0/msr not found. Is the 'msr' kernel module loaded?", file=sys.stderr)
         print("       Try: sudo modprobe msr", file=sys.stderr)
         # Decide whether to exit or continue without MSRs
         # exit(1) # Exit if MSRs are critical

    main()
