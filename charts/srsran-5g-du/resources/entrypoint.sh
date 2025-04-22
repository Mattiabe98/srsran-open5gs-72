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

# Wait for VPP socket to exist so we can talk to it
while [ ! -e /run/vpp/cli.sock ]; do
    sleep 0.2
done

vppctl create interface memif id 0 socket-id 0 socket /run/memif/memif.sock slave
vppctl set interface state memif0 up
vppctl set interface ip address memif0 192.168.100.2/30

echo N | tee /sys/module/drm_kms_helper/parameters/poll >/dev/null
/opt/dpdk/23.11.1/bin/dpdk-devbind.py --bind vfio-pci 0000:51:11.0
stdbuf -oL -eL /usr/local/bin/srsdu -c /gnb.yml
