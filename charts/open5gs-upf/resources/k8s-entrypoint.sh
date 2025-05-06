#!/bin/bash
set -e

echo "Executing k8s customized entrypoint.sh"

# --- Modification Start ---
# Use Scratch to store the TUN device name across scopes
{{- $_ := $.Scratch.Set "tunDev" "" }} {{/* Initialize scratch variable */}}

# Determine the device name from the first entry that creates it
{{- range $index, $subnet := .Values.config.subnetList }}
  {{- if and (not ($.Scratch.Get "tunDev")) .createDev }}
    {{- $_ := $.Scratch.Set "tunDev" .dev }} {{/* Set scratch variable if found */}}
  {{- end }}
{{- end }}

# Fallback if no entry explicitly creates it, but list is not empty
{{- if and (not ($.Scratch.Get "tunDev")) (gt (len .Values.config.subnetList) 0) }}
  {{- $_ := $.Scratch.Set "tunDev" (first .Values.config.subnetList).dev }} {{/* Set scratch variable from first entry */}}
{{- end }}

# Retrieve the determined TUN device name from Scratch
{{- $TUN_DEV := $.Scratch.Get "tunDev" }}

{{- /* Now proceed only if a TUN device name was determined */}}
{{- if $TUN_DEV }}
  echo "Ensuring net device {{ $TUN_DEV }} exists and is up"
  if ! grep "{{ $TUN_DEV }}" /proc/net/dev > /dev/null; then
      echo "Creating net device {{ $TUN_DEV }}"
      ip tuntap add name {{ $TUN_DEV }} mode tun
      ip link set {{ $TUN_DEV }} up
  else
      echo "Net device {{ $TUN_DEV }} already exists."
      ip link set {{ $TUN_DEV }} up # Ensure it's up
  fi

  sysctl -w net.ipv4.ip_forward=1

  # Assign IPs and Add NAT rules for ALL subnets using the determined device
  {{- range .Values.config.subnetList }}
    {{- /* Check if the current subnet's device matches the one we determined */}}
    {{- if eq .dev $TUN_DEV }}
      echo "Setting IP {{ .gateway }}/{{ .mask }} for subnet {{ .subnet }} on device {{ .dev }}"
      # Check if IP already exists before adding (optional, but good practice)
      if ! ip addr show {{ .dev }} | grep -q "inet {{ .gateway }}/"; then
         ip addr add {{ .gateway }}/{{ .mask }} dev {{ .dev }}
      else
         echo "IP {{ .gateway }} already configured on {{ .dev }}"
      fi

      {{- if .enableNAT }}
        echo "Enable NAT for {{ .subnet }} via device {{ .dev }}"
        # Check if rule already exists (optional, prevents duplicates on restart)
        if ! iptables -t nat -C POSTROUTING -s {{ .subnet }} ! -o {{ .dev }} -j MASQUERADE > /dev/null 2>&1; then
           iptables -t nat -A POSTROUTING -s {{ .subnet }} ! -o {{ .dev }} -j MASQUERADE
        else
           echo "NAT rule for {{ .subnet }} already exists."
        fi
      {{- end }}
    {{- else }}
      # This log might be confusing if multiple dev names are used intentionally, adjust if needed
      # echo "Skipping IP/NAT setup for subnet {{ .subnet }} - device {{ .dev }} does not match primary TUN device {{ $TUN_DEV }}"
    {{- end }}
  {{- end }} {{- /* End of range loop for IPs/NAT */}}
{{- else }}
  echo "Warning: No TUN device specified or determined from subnetList in values.yaml."
{{- end }} {{- /* End of if $TUN_DEV */}}
# --- Modification End ---


echo "Updating iPerf3.."
# Consider making iperf3 download optional based on a value if needed
curl -kL https://github.com/userdocs/iperf3-static/releases/download/3.18/iperf3-amd64 -o /usr/bin/iperf3
chmod +x /usr/bin/iperf3 # Ensure it's executable

# Execute the original command passed to the container (e.g., open5gs-upfd)
$@
