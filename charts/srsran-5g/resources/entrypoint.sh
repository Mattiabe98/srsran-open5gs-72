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



sed -e "s/\${AMF_BIND_ADDR}/$AMF_BIND_ADDR/g" \
    -e "s/\${AMF_ADDR}/$AMF_ADDR/g" \
    -e "s/\${E2_ADDR}/$E2_ADDR/g" \
    < /gnb-template.yml > /gnb.yml

echo N | tee /sys/module/drm_kms_helper/parameters/poll >/dev/null
/opt/dpdk/23.11.1/bin/dpdk-devbind.py --bind vfio-pci 0000:01:00.0
/usr/local/bin/gnb -c /gnb.yml
