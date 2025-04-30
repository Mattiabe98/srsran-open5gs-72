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
MSR_IA32_MPERF = 0xE7
MSR_IA32_APERF = 0xE8
MSR_IA32_THERM_STATUS = 0x19C
MSR_IA32_PACKAGE_THERM_STATUS = 0x1B1
MSR_IA32_TEMPERATURE_TARGET = 0x1A2
MSR_IA32_FIXED_CTR0 = 0x309 # Instructions Retired
MSR_IA32_FIXED_CTR1 = 0x30A # Unhalted Core Cycles

# --- Constants ---
MAX_CPUIDLE_STATES = 10
PSTATE_BASE_PATH = "/sys/devices/system/cpu/intel_pstate"

# --- Helper Functions ---
def read_sysfs_int(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        data = os.read(fd, 32); os.close(fd)
        return int(data.strip())
    except: return None

def read_sysfs_str(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        data = os.read(fd, 128); os.close(fd)
        return data.strip().decode('utf-8', errors='ignore')
    except: return None

def read_msr(cpu_id, reg):
    try:
        fd = os.open(f'/dev/cpu/{cpu_id}/msr', os.O_RDONLY | os.O_CLOEXEC)
        msr_val_bytes = os.pread(fd, 8, reg); os.close(fd)
        return struct.unpack('<Q', msr_val_bytes)[0]
    except OSError: return None

def parse_interrupts():
    irq_counts = defaultdict(int); cpu_columns = {}
    try:
        with open('/proc/interrupts', 'r') as f: lines = f.readlines()
        if not lines: return irq_counts
        header = lines[0].split()
        for idx, col_name in enumerate(header):
             if col_name.startswith('CPU'):
                 try: cpu_columns[idx] = int(col_name[3:])
                 except ValueError: continue
        if not cpu_columns: return irq_counts
        for line in lines[1:]:
            parts = line.split()
            if not parts or not (parts[0].endswith(':') or parts[0].isdigit()): continue
            for col_idx, cpu_id in cpu_columns.items():
                if col_idx < len(parts):
                    try: irq_counts[cpu_id] += int(parts[col_idx])
                    except (ValueError, IndexError): continue
    except Exception as e: print(f"Warning: Parsing /proc/interrupts: {e}")
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
        for path in glob.glob(os.path.join(powercap_base, "intel-rapl:*")):
            if os.path.isdir(path) and ':' not in os.path.basename(path).split(':')[-1]:
                name = read_sysfs_str(os.path.join(path, "name"))
                energy_path = os.path.join(path, "energy_uj")
                max_energy_path = os.path.join(path, "max_energy_range_uj")
                if name and name.startswith("package") and os.path.exists(energy_path) and os.path.exists(max_energy_path):
                    try: id_ = int(name.split('-')[-1]); domains['pkg'].append({'id': id_, 'path': energy_path, 'max_path': max_energy_path})
                    except: domains['pkg'].append({'id': -1, 'path': energy_path, 'max_path': max_energy_path})
        for path in glob.glob(os.path.join(powercap_base, "intel-rapl:*:*")):
             if os.path.isdir(path):
                 name = read_sysfs_str(os.path.join(path, "name"))
                 energy_path = os.path.join(path, "energy_uj")
                 max_energy_path = os.path.join(path, "max_energy_range_uj")
                 if name == "dram" and os.path.exists(energy_path) and os.path.exists(max_energy_path):
                     try:
                         parent = os.path.basename(os.path.dirname(path)); id_ = int(parent.split(':')[-1])
                         domains['dram'].append({'id': id_, 'path': energy_path, 'max_path': max_energy_path})
                     except: domains['dram'].append({'id': -1, 'path': energy_path, 'max_path': max_energy_path})
        domains['pkg'].sort(key=lambda x: x['id']); domains['dram'].sort(key=lambda x: x['id'])
    except Exception as e: print(f"Warning: Finding RAPL domains: {e}")
    return domains

def get_cpuidle_state_info(cpu_id):
    state_info = {}; base_path = f'/sys/devices/system/cpu/cpu{cpu_id}/cpuidle'
    try:
        if not os.path.isdir(base_path): return state_info
        for i in range(MAX_CPUIDLE_STATES):
            name_path = os.path.join(base_path, f'state{i}/name'); time_path = os.path.join(base_path, f'state{i}/time')
            if not os.path.exists(name_path): continue
            name = read_sysfs_str(name_path)
            if name and os.path.exists(time_path): state_info[name] = {'time': time_path}
    except Exception as e: print(f"Warning: Probing cpuidle for CPU {cpu_id}: {e}")
    return state_info

def get_effective_cpus():
    paths = ['/sys/fs/cgroup/cpuset.cpus.effective', '/sys/fs/cgroup/cpuset/cpuset.effective_cpus']
    cpu_str = None; path_read = None
    for path in paths:
        if os.path.exists(path):
            path_read = path
            try:
                with open(path, 'r') as f: cpu_str = f.read().strip()
                if cpu_str: break
            except Exception as e: print(f"Warning: Reading {path}: {e}.")
    if cpu_str is None or cpu_str == "":
        try: return sorted(list(os.sched_getaffinity(0)))
        except OSError: print("Error: Cannot get process affinity."); return []
    cpus = set()
    for part in cpu_str.split(','):
        try:
            if '-' in part: start, end = map(int, part.split('-')); cpus.update(range(start, end + 1))
            elif part: cpus.add(int(part))
        except ValueError: print(f"Warning: Parsing part '{part}' in '{cpu_str}'")
    return sorted(list(cpus))

def print_pstate_info():
    info = {'min_perf_pct': None, 'max_perf_pct': None}
    if not os.path.exists(PSTATE_BASE_PATH):
        print("intel_pstate sysfs directory not found.")
        return info
    status = read_sysfs_str(os.path.join(PSTATE_BASE_PATH, "status"))
    no_turbo = read_sysfs_int(os.path.join(PSTATE_BASE_PATH, "no_turbo"))
    hwp_boost = read_sysfs_int(os.path.join(PSTATE_BASE_PATH, "hwp_dynamic_boost"))
    info['min_perf_pct'] = os.path.join(PSTATE_BASE_PATH, "min_perf_pct")
    info['max_perf_pct'] = os.path.join(PSTATE_BASE_PATH, "max_perf_pct")
    print("--- Intel P-State Info ---", flush=True)
    print(f" Status:\t{status if status is not None else 'N/A'}", flush=True)
    print(f" No Turbo:\t{no_turbo if no_turbo is not None else 'N/A'} (1=disabled, 0=enabled)", flush=True)
    print(f" HWP Boost:\t{hwp_boost if hwp_boost is not None else 'N/A'} (1=enabled, 0=disabled)", flush=True)
    print("--------------------------", flush=True)
    return info


# --- Data Structures ---
class CPUData:
    def __init__(self):
        self.timestamp = 0.0
        self.tsc = 0
        self.aperf = 0
        self.mperf = 0
        self.instr_retired = 0 # Added IPC
        self.core_cycles = 0   # Added IPC
        self.irq_count = 0
        self.core_temp = None
        self.core_throttled = False
        self.actual_mhz = None
        self.governor = None
        self.epb = None
        self.min_perf_pct = None
        self.max_perf_pct = None
        self.cstate_time = defaultdict(int)

    def delta(self, prev):
        if not isinstance(prev, CPUData) or self.timestamp <= prev.timestamp:
             if self.timestamp == prev.timestamp and self.tsc == prev.tsc: pass
             else: return None
        if self.tsc < prev.tsc: return None

        d = CPUData(); d.timestamp = self.timestamp - prev.timestamp
        if d.timestamp == 0: d.timestamp = 1e-9

        d.tsc = self.tsc - prev.tsc
        d.aperf = self.aperf - prev.aperf if self.aperf >= prev.aperf else (2**64 - prev.aperf) + self.aperf
        d.mperf = self.mperf - prev.mperf if self.mperf >= prev.mperf else (2**64 - prev.mperf) + self.mperf
        d.instr_retired = self.instr_retired - prev.instr_retired if self.instr_retired >= prev.instr_retired else (2**64 - prev.instr_retired) + self.instr_retired
        d.core_cycles = self.core_cycles - prev.core_cycles if self.core_cycles >= prev.core_cycles else (2**64 - prev.core_cycles) + self.core_cycles
        d.irq_count = self.irq_count - prev.irq_count

        d.core_temp = self.core_temp
        d.core_throttled = self.core_throttled
        d.actual_mhz = self.actual_mhz
        d.governor = self.governor
        d.epb = self.epb
        d.min_perf_pct = self.min_perf_pct
        d.max_perf_pct = self.max_perf_pct

        for name, time_now in self.cstate_time.items():
            time_prev = prev.cstate_time.get(name, 0)
            d.cstate_time[name] = time_now - time_prev if time_now >= time_prev else (2**64 - time_prev) + time_now
        return d

def calculate_delta_energy(current_uj, prev_uj, max_range_uj):
    """Calculates energy delta correctly handling wrap-around based on max_range."""
    if max_range_uj <= 0: max_range_uj = 2**64 # Fallback
    if current_uj >= prev_uj: delta = current_uj - prev_uj
    else: delta = (max_range_uj - prev_uj) + current_uj
    if delta > max_range_uj: return 0 # Sanity check fail
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
        if d.timestamp == 0: d.timestamp = 1e-9
        d.pkg_temp = self.pkg_temp
        d.energy_pkg_uj = calculate_delta_energy(self.energy_pkg_uj, prev.energy_pkg_uj, self.max_energy_pkg_uj)
        d.energy_dram_uj = calculate_delta_energy(self.energy_dram_uj, prev.energy_dram_uj, self.max_energy_dram_uj)
        d.max_energy_pkg_uj = self.max_energy_pkg_uj
        d.max_energy_dram_uj = self.max_energy_dram_uj
        return d

# --- Data Collection ---

def get_all_counters(target_cpus, topology, tjmax, rapl_domains_info, cpuidle_state_info, pstate_paths):
    """Reads all relevant counters using MSR and sysfs."""
    current_irqs = parse_interrupts()
    timestamp = time.monotonic()

    cpu_data = {cpu: CPUData() for cpu in target_cpus}
    all_pkg_ids = {info['pkg_id'] for info in topology.values() if info['pkg_id'] != -1}
    pkg_data = {pkg_id: PkgData() for pkg_id in all_pkg_ids}

    min_perf = read_sysfs_int(pstate_paths.get('min_perf_pct'))
    max_perf = read_sysfs_int(pstate_paths.get('max_perf_pct'))

    cores_visited_for_temps = set()
    pkgs_visited_for_temps = set()
    pkgs_visited_for_rapl = set()

    # --- Read Global/Package values ONCE per interval ---
    for pkg_id in all_pkg_ids:
        p_data = pkg_data[pkg_id]
        p_data.timestamp = timestamp
        rep_cpu = -1
        for c, t in topology.items():
            if t['pkg_id'] == pkg_id: rep_cpu = c; break
        if rep_cpu == -1: continue

        pkg_therm_stat = read_msr(rep_cpu, MSR_IA32_PACKAGE_THERM_STATUS)
        if pkg_therm_stat is not None:
            dts = (pkg_therm_stat >> 16) & 0x7F
            p_data.pkg_temp = tjmax - dts

        pkg_rapl_info, dram_rapl_info = None, None
        for domain in rapl_domains_info.get('pkg', []):
             if domain['id'] == pkg_id: pkg_rapl_info = domain; break
        if not pkg_rapl_info and len(rapl_domains_info.get('pkg', [])) == 1 and rapl_domains_info['pkg'][0]['id'] == -1:
             pkg_rapl_info = rapl_domains_info['pkg'][0]
        for domain in rapl_domains_info.get('dram', []):
             if domain['id'] == pkg_id: dram_rapl_info = domain; break
        if not dram_rapl_info and len(rapl_domains_info.get('dram', [])) == 1 and rapl_domains_info['dram'][0]['id'] == -1:
             if len(all_pkg_ids) == 1 or pkg_id == 0:
                 dram_rapl_info = rapl_domains_info['dram'][0]

        if pkg_rapl_info:
            p_data.max_energy_pkg_uj = read_sysfs_int(pkg_rapl_info['max_path']) or (2**64 -1)
            p_data.energy_pkg_uj = read_sysfs_int(pkg_rapl_info['path']) or 0
        if dram_rapl_info:
            p_data.max_energy_dram_uj = read_sysfs_int(dram_rapl_info['max_path']) or (2**64 -1)
            p_data.energy_dram_uj = read_sysfs_int(dram_rapl_info['path']) or 0


    # --- Read Per-CPU values ---
    for cpu_id in target_cpus:
        data = cpu_data[cpu_id]
        data.timestamp = timestamp
        data.tsc = read_msr(cpu_id, MSR_IA32_TSC) or 0
        data.aperf = read_msr(cpu_id, MSR_IA32_APERF) or 0
        data.mperf = read_msr(cpu_id, MSR_IA32_MPERF) or 0
        data.instr_retired = read_msr(cpu_id, MSR_IA32_FIXED_CTR0) or 0 # Read Inst Retired
        data.core_cycles = read_msr(cpu_id, MSR_IA32_FIXED_CTR1) or 0   # Read Core Cycles
        data.irq_count = current_irqs.get(cpu_id, 0)
        act_mhz_khz = read_sysfs_int(f'/sys/devices/system/cpu/cpu{cpu_id}/cpufreq/scaling_cur_freq')
        data.actual_mhz = act_mhz_khz / 1000 if act_mhz_khz is not None else None
        data.governor = read_sysfs_str(f'/sys/devices/system/cpu/cpu{cpu_id}/cpufreq/scaling_governor')
        data.epb = read_sysfs_int(f'/sys/devices/system/cpu/cpu{cpu_id}/power/energy_perf_bias')
        data.min_perf_pct = min_perf
        data.max_perf_pct = max_perf

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
                dts = (therm_stat >> 16) & 0x7F
                temp_val = tjmax - dts
                throttled_val = bool(therm_stat & 0x01 or therm_stat & 0x02)
            for c_id in target_cpus:
                 if topology[c_id]['core_id'] == core_id:
                     cpu_data[c_id].core_temp = temp_val
                     cpu_data[c_id].core_throttled = throttled_val

    return cpu_data, pkg_data

# --- Main Loop ---

def main():
    parser = argparse.ArgumentParser(description="Python Turbostat Replacement (Subset with Sysfs)")
    parser.add_argument("-i", "--interval", type=float, default=5.0, help="Measurement interval (sec)")
    parser.add_argument("-c", "--cpu", type=str, default=None, help="CPUs to monitor (default: effective cgroup)")
    parser.add_argument("-N", "--header-interval", type=int, default=22, help="Reprint header every N measurement intervals (default: 22)")
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("Warning: Needs root/privileged access for MSRs.", flush=True)

    target_cpus = []
    if args.cpu:
         try:
             cpus_specified = set()
             for part in args.cpu.split(','):
                if '-' in part: start, end = map(int, part.split('-')); cpus_specified.update(range(start, end + 1))
                elif part: cpus_specified.add(int(part))
             target_cpus = sorted(list(cpus_specified))
         except ValueError: print(f"Error: Invalid CPU list format: {args.cpu}"); exit(1)
    else: target_cpus = get_effective_cpus()

    if not target_cpus: print("Error: No target CPUs found or specified."); exit(1)

    num_target_cpus = len(target_cpus)
    print(f"Monitoring CPUs: {','.join(map(str, target_cpus))}", flush=True)
    print("Starting measurements...", flush=True)

    topology = get_cpu_topology(target_cpus)
    first_cpu = -1
    for cpu_id in target_cpus:
         if topology.get(cpu_id) and topology[cpu_id]['pkg_id'] != -1: first_cpu = cpu_id; break
    if first_cpu == -1: first_cpu = target_cpus[0]

    tjmax = get_tjmax(first_cpu)
    rapl_domains_info = find_rapl_domains()
    cpuidle_state_info = {cpu: get_cpuidle_state_info(cpu) for cpu in target_cpus}
    pstate_info = print_pstate_info()

    print(f"Using TjMax: {tjmax}°C", flush=True)
    if not rapl_domains_info['pkg']: print("Warning: No package RAPL domain found via powercap.", flush=True)
    if not rapl_domains_info['dram']: print("Warning: No DRAM RAPL domain found via powercap.", flush=True)

    # --- Correct Initialization ---
    print("Taking initial measurement...", flush=True)
    prev_cpu_data, prev_pkg_data = get_all_counters(target_cpus, topology, tjmax, rapl_domains_info, cpuidle_state_info, pstate_info)
    time.sleep(args.interval)
    # --------------------------

    iteration = 0
    rows_since_header = 0
    max_rows_before_header = args.header_interval * num_target_cpus

    # Define Header - Added POLL%, IPC. Adjusted widths. TAB delimiter.
    #                Core CPU  ActMHz   Avg_MHz   Busy%   Bzy_MHz   TSC_MHz      IPC         IRQ   POLL%    C1%   C1E%    C6% CoreTmp CoreThr  PkgTmp MinP% MaxP% Governor   EPB PkgWatt RAMWatt
    header_fmt = "{:<4}\t{:<3}\t{:>7}\t{:>7}\t{:>5}\t{:>7}\t{:>7}\t{:>4}\t{:>10}\t{:>5}\t{:>5}\t{:>5}\t{:>5}\t{:>7}\t{:>7}\t{:>7}\t{:>4}\t{:>4}\t{:>11}\t{:>3}\t{:>7}\t{:>7}"
    header_str = header_fmt.format(
        "Core", "CPU", "ActMHz", "Avg_MHz", "Busy%", "Bzy_MHz", "TSC_MHz", "IPC", # Added IPC
        "IRQ", "POLL%", "C1%", "C1E%", "C6%",
        "CoreTmp", "CoreThr", "PkgTmp", "MinP%", "MaxP%",
        "Governor", "EPB",
        "PkgWatt", "RAMWatt"
    )

    while True:
        try:
            current_cpu_data, current_pkg_data = get_all_counters(target_cpus, topology, tjmax, rapl_domains_info, cpuidle_state_info, pstate_info)

            delta_cpu_data = {}
            delta_pkg_data = {}
            valid_delta = True

            for cpu_id in target_cpus:
                if cpu_id not in prev_cpu_data: valid_delta = False; break
                delta = current_cpu_data[cpu_id].delta(prev_cpu_data[cpu_id])
                if delta is None: valid_delta = False; break
                delta_cpu_data[cpu_id] = delta
            if valid_delta:
                 for pkg_id in current_pkg_data:
                      if pkg_id not in prev_pkg_data: valid_delta = False; break
                      delta = current_pkg_data[pkg_id].delta(prev_pkg_data[pkg_id])
                      if delta is None: valid_delta = False; break
                      delta_pkg_data[pkg_id] = delta

            if valid_delta:
                if rows_since_header == 0:
                    utc_now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')
                    print(f"\n--- {utc_now} ---", flush=True)
                    print(header_str, flush=True)

                for cpu_id in target_cpus:
                    delta = delta_cpu_data[cpu_id]
                    interval_sec = delta.timestamp
                    core_id_val = topology[cpu_id]['core_id']
                    pkg_id = topology[cpu_id]['pkg_id']

                    # --- Calculations ---
                    avg_mhz = delta.aperf / (interval_sec * 1_000_000) if interval_sec > 0 else 0
                    busy_pct = 100.0 * delta.mperf / delta.tsc if delta.tsc > 0 else 0.0
                    tsc_mhz = delta.tsc / (interval_sec * 1_000_000) if interval_sec > 0 else 0
                    bzy_mhz = (delta.aperf / delta.mperf) * tsc_mhz if delta.mperf > 0 and tsc_mhz > 0 else 0.0
                    ipc = delta.instr_retired / delta.core_cycles if delta.core_cycles > 0 else 0.0 # Calculate IPC

                    interval_us = interval_sec * 1_000_000
                    poll_time_delta = delta.cstate_time.get('POLL', 0) # Look for POLL state
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

                    # --- Formatting Data Row ---
                    print(header_fmt.format(
                        str(core_id_val) if core_id_val != -1 else "",        # Core
                        cpu_id,                                                # CPU
                        f"{delta.actual_mhz:.1f}" if delta.actual_mhz is not None else "", # ActMHz
                        f"{avg_mhz:.1f}",                                     # Avg_MHz
                        f"{busy_pct:.2f}",                                   # Busy%
                        f"{bzy_mhz:.1f}",                                     # Bzy_MHz
                        f"{tsc_mhz:.1f}",                                     # TSC_MHz
                        f"{ipc:.2f}",                                         # IPC << ADDED
                        delta.irq_count if delta.irq_count is not None else "", # IRQ
                        f"{poll_pct:.2f}",                                   # POLL% << ADDED
                        f"{c1_pct:.2f}",                                     # C1%
                        f"{c1e_pct:.2f}",                                    # C1E%
                        f"{c6_pct:.2f}",                                     # C6%
                        str(delta.core_temp) if delta.core_temp is not None else "", # CoreTmp
                        "Y" if delta.core_throttled else "N",                   # CoreThr
                        str(d_pkg.pkg_temp) if d_pkg and d_pkg.pkg_temp is not None else "", # PkgTmp
                        str(delta.min_perf_pct) if delta.min_perf_pct is not None else "", # MinP%
                        str(delta.max_perf_pct) if delta.max_perf_pct is not None else "", # MaxP%
                        str(delta.governor)[:11] if delta.governor else "",      # Governor
                        str(delta.epb) if delta.epb is not None else "",        # EPB
                        f"{pkg_watt_val:.2f}",                               # PkgWatt
                        f"{ram_watt_val:.2f}"                                # RAMWatt
                    ), flush=True)
                    rows_since_header += 1

                if rows_since_header >= max_rows_before_header:
                    rows_since_header = 0
            else:
                 print(f"Skipping print for interval {iteration+1} due to invalid delta.", flush=True)

            prev_cpu_data = current_cpu_data
            prev_pkg_data = current_pkg_data
            iteration += 1
            time.sleep(args.interval)

        except KeyboardInterrupt:
            print("\nExiting.")
            break
        except Exception as e:
            print(f"\nRuntime error on iteration {iteration}: {e}", flush=True)
            import traceback
            traceback.print_exc()
            time.sleep(args.interval)

if __name__ == "__main__":
    main()
