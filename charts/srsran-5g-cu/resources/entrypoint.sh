#!/bin/bash

set -ex

resolve_ip() {
    python3 -c "import socket; print(socket.gethostbyname('$1'))" 2>/dev/null
}

if [[ -n "$AMF_HOSTNAME" ]]; then 
    export AMF_ADDR="$(resolve_ip "$AMF_HOSTNAME")"
fi

if [[ -z "${AMF_BIND_ADDR}" ]] ; then
    export AMF_BIND_ADDR=$(hostname -I)
fi

if [[ ! -z "$GNB_HOSTNAME" ]] ; then 
    export GNB_ADDRESS="$(resolve_ip "$GNB_HOSTNAME")"
fi


if [[ ! -z "$UE_HOSTNAME" ]] ; then 
    export UE_ADDRESS="$(resolve_ip "$UE_HOSTNAME")"
fi

export E2_ADDR=$(resolve_ip "$E2_HOSTNAME")


sed -e "s/\${AMF_BIND_ADDR}/$AMF_BIND_ADDR/g" \
    -e "s/\${AMF_ADDR}/$AMF_ADDR/g" \
    -e "s/\${E2_ADDR}/$E2_ADDR/g" \
    < /gnb-template.yml > /gnb.yml


vpp -c /etc/vpp/startup.conf &

# Wait for VPP socket
VPP_SOCK="/run/vpp/cli-cu.sock"
echo "Waiting for VPP socket $VPP_SOCK..."
while [ ! -S "$VPP_SOCK" ]; do sleep 0.2; done
echo "VPP socket found."

# --- VPP Configuration ---
VPP_TAP_IF_NAME="tap-cu" # Kernel interface name VPP will create
VPP_TAP_IP="10.10.1.2"   # VPP's IP on the tap link
KERNEL_TAP_IP="10.10.1.1" # Kernel's IP on the tap link
TAP_SUBNET="10.10.1.0/24"
TAP_CIDR="24"

REMOTE_MEMIF_IP="10.10.2.2"
REMOTE_KERNEL_IP="10.10.1.3"
LOCAL_MEMIF_IP="10.10.2.1"
MEMIF_SUBNET="10.10.2.0/24"

echo "Configuring VPP TAP interface..."
# Create tapv2 interface (id 0), let VPP create kernel dev named tap-cu
# Optional: Can set host ip here too with `host-ip4-addr KERNEL_TAP_IP/TAP_CIDR`
VPP_TAP_RX_RING=4096
VPP_TAP_TX_RING=4096

vppctl -s "$VPP_SOCK" create tap id 0 host-if-name "$VPP_TAP_IF_NAME" 
#  rx-ring-size $VPP_TAP_RX_RING tx-ring-size $VPP_TAP_TX_RING

echo "Assigning IP to VPP TAP interface tap0..."
vppctl -s "$VPP_SOCK" set int ip address tap0 "$VPP_TAP_IP/$TAP_CIDR"
vppctl -s "$VPP_SOCK" set int state tap0 up

# Wait for kernel interface to appear
echo "Waiting for kernel TAP interface $VPP_TAP_IF_NAME..."
while ! ip link show "$VPP_TAP_IF_NAME" > /dev/null 2>&1; do sleep 0.2; done
echo "Kernel TAP interface found."

# --- Kernel Configuration ---
echo "Configuring kernel TAP interface..."
ip link set dev "$VPP_TAP_IF_NAME" up
ip addr add "$KERNEL_TAP_IP/$TAP_CIDR" dev "$VPP_TAP_IF_NAME"

# --- Memif Configuration ---
echo "Configuring Memif interface..."
vppctl -s "$VPP_SOCK" create memif socket id 1 filename /run/memif/memif.sock
vppctl -s "$VPP_SOCK" create interface memif id 0 socket-id 1 master
vppctl -s "$VPP_SOCK" set int state memif1/0 up
vppctl -s "$VPP_SOCK" set int ip address memif1/0 "$LOCAL_MEMIF_IP/$TAP_CIDR" # Assuming /24 for memif too

# --- Routing ---
echo "Configuring routes..."
# Kernel: Reach memif net via VPP's tap IP
ip route add "$MEMIF_SUBNET" via "$VPP_TAP_IP" dev "$VPP_TAP_IF_NAME"
# Kernel: Reach remote kernel IP via VPP's tap IP
ip route add "$REMOTE_KERNEL_IP/32" via "$VPP_TAP_IP" dev "$VPP_TAP_IF_NAME"

# VPP: Reach remote kernel IP via remote memif IP
vppctl -s "$VPP_SOCK" ip route add "$REMOTE_KERNEL_IP/32" via "$REMOTE_MEMIF_IP" memif1/0

echo "CU Configuration Complete."
# echo N | tee /sys/module/drm_kms_helper/parameters/poll >/dev/null
# stdbuf -oL -eL /usr/local/bin/srscu -c /gnb.yml
apt update && apt install -y iputils-ping
sleep infinity
