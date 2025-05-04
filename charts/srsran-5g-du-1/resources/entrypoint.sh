#!/bin/bash

set -ex

resolve_ip() {
    python3 -c "import socket; print(socket.gethostbyname('$1'))" 2>/dev/null
}

# Resolve addresses
if [[ -n "$AMF_HOSTNAME" ]]; then 
    export AMF_ADDR="$(resolve_ip "$AMF_HOSTNAME")"
fi

if [[ -z "${AMF_BIND_ADDR}" ]] ; then
    export AMF_BIND_ADDR=$(hostname -I | awk '{print $1}')
fi

if [[ ! -z "$GNB_HOSTNAME" ]] ; then 
    export GNB_ADDRESS="$(resolve_ip "$GNB_HOSTNAME")"
fi

if [[ ! -z "$UE_HOSTNAME" ]] ; then 
    export UE_ADDRESS="$(resolve_ip "$UE_HOSTNAME")"
fi

export E2_ADDR=$(resolve_ip "$E2_HOSTNAME")

# Generate config
sed -e "s/\${AMF_BIND_ADDR}/$AMF_BIND_ADDR/g" \
    -e "s/\${AMF_ADDR}/$AMF_ADDR/g" \
    -e "s/\${E2_ADDR}/$E2_ADDR/g" \
    < /gnb-template.yml > /gnb.yml

# Disable polling for display driver
echo N | tee /sys/module/drm_kms_helper/parameters/poll >/dev/null

# DPDK device bind
/opt/dpdk/23.11.1/bin/dpdk-devbind.py --bind vfio-pci 0000:51:11.4
# Launch srsDU in the foreground
sleep 1000
stdbuf -oL -eL /usr/local/bin/srsdu -c /gnb.yml
