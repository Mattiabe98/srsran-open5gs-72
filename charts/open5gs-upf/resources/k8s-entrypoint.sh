#!/bin/bash
set -e

echo "Executing k8s customized entrypoint.sh"

# --- Modification Start ---
# Determine the device name from the first entry that creates it (or use a fixed default if needed)
TUN_DEV=""
{{- range $index, $subnet := .Values.config.subnetList }}
{{- if and (not $TUN_DEV) .createDev }}
{{- $TUN_DEV = .dev }}
{{- end }}
{{- end }}
# Fallback if no entry explicitly creates it, but list is not empty
{{- if and (not $TUN_DEV) (gt (len .Values.config.subnetList) 0) }}
{{- $TUN_DEV = (first .Values.config.subnetList).dev }}
{{- end }}


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

  # Assign IPs and Add NAT rules for ALL subnets using the same device
  {{- range .Values.config.subnetList }}
    {{- if eq .dev $TUN_DEV }} # Process only entries for the chosen TUN device
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
      echo "Skipping IP/NAT setup for subnet {{ .subnet }} - device {{ .dev }} does not match primary TUN device {{ $TUN_DEV }}"
    {{- end }}
  {{- end }}
{{- else }}
  echo "No TUN device specified or created in subnetList."
{{- end }}
# --- Modification End ---


echo "Updating iPerf3.."
curl -kL https://github.com/userdocs/iperf3-static/releases/download/3.18/iperf3-amd64 -o /usr/bin/iperf3

# Execute the original command passed to the container
$@
