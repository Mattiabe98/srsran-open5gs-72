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
while [ ! -e /run/vpp/cli-cu.sock ]; do
    sleep 0.2
done

ip link add name vpp1out type veth peer name vpp1host
ip link set dev vpp1out up
ip link set dev vpp1host up
ip addr add 10.10.1.1/24 dev vpp1host

vppctl -s /run/vpp/cli-cu.sock create host-interface name vpp1out
vppctl -s /run/vpp/cli-cu.sock set int state host-vpp1out up
vppctl -s /run/vpp/cli-cu.sock set int ip address host-vpp1out 10.10.1.2/24

vppctl -s /run/vpp/cli-cu.sock create memif socket id 1 filename /run/memif/memif.sock
vppctl -s /run/vpp/cli-cu.sock create interface memif id 0 socket-id 1 master
vppctl -s /run/vpp/cli-cu.sock set int state memif1/0 up
vppctl -s /run/vpp/cli-cu.sock set int ip address memif1/0 10.10.2.1/24

ip route add 10.10.2.0/24 via 10.10.1.2

vppctl -s /run/vpp/cli-cu.sock ip route add 10.10.1.0/24 via 10.10.2.1

echo N | tee /sys/module/drm_kms_helper/parameters/poll >/dev/null
stdbuf -oL -eL /usr/local/bin/srscu -c /gnb.yml
