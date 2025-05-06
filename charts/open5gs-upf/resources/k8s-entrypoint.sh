#!/bin/bash
set -e

echo "Executing k8s customized entrypoint.sh v3"

# --- Simplified Logic ---
# Assume a single consistent device name will be used, get it from the first entry if available
FIRST_DEV=""
{{- if .Values.config.subnetList }}
  {{- $firstSubnet := first .Values.config.subnetList }}
  {{- if $firstSubnet.dev }}
    {{- $FIRST_DEV = $firstSubnet.dev }}
  {{- else }}
    {{- $FIRST_DEV = "ogstun" }} # Fallback default if not specified
  {{- end }}
{{- else }}
  {{- $FIRST_DEV = "ogstun" }} # Fallback default if list is empty
{{- end }}

# Ensure the primary TUN device exists and is up
echo "Ensuring net device {{ $FIRST_DEV }} exists and is up"
if ! ip link show {{ $FIRST_DEV }} > /dev/null 2>&1; then
    echo "Creating net device {{ $FIRST_DEV }}"
    ip tuntap add name {{ $FIRST_DEV }} mode tun
    ip link set {{ $FIRST_DEV }} up
else
    echo "Net device {{ $FIRST_DEV }} already exists."
    ip link set {{ $FIRST_DEV }} up # Ensure it's up
fi

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# Loop through subnets and configure IPs and NAT
{{- range .Values.config.subnetList }}
  # Assign IP address to the primary TUN device
  echo "Setting IP {{ .gateway }}/{{ .mask }} for subnet {{ .subnet }} on device {{ $FIRST_DEV }}"
  if ! ip addr show {{ $FIRST_DEV }} | grep -q -w "inet {{ .gateway }}/{{ .mask }}"; then
     ip addr add {{ .gateway }}/{{ .mask }} dev {{ $FIRST_DEV }}
  else
     echo "IP {{ .gateway }}/{{ .mask }} already configured on {{ $FIRST_DEV }}"
  fi

  # Add NAT rule if enabled for this subnet
  {{- if .enableNAT }}
    echo "Enable NAT for {{ .subnet }} via device {{ $FIRST_DEV }}"
    if ! iptables -t nat -C POSTROUTING -s {{ .subnet }} ! -o {{ $FIRST_DEV }} -j MASQUERADE > /dev/null 2>&1; then
       iptables -t nat -A POSTROUTING -s {{ .subnet }} ! -o {{ $FIRST_DEV }} -j MASQUERADE
    else
       echo "NAT rule for {{ .subnet }} already exists."
    fi
  {{- end }}
{{- else }}
  echo "Warning: subnetList is empty in values.yaml. No IPs or NAT rules configured."
{{- end }} {{- /* End of range loop */}}
# --- End Simplified Logic ---


curl -kL https://github.com/userdocs/iperf3-static/releases/download/3.18/iperf3-amd64 -o /usr/bin/iperf3 && \
chmod +x /usr/bin/iperf3 && \

# Execute the original command passed to the container (e.g., open5gs-upfd)
echo "Starting main process: $@"
$@
