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

/usr/local/bin/gnb -c /gnb.yml
