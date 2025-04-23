#!/bin/bash

set -ex

resolve_ip() {
    python3 -c "import socket; print(socket.gethostbyname('$1'))" 2>/dev/null
}

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


sed -e "s/\${AMF_BIND_ADDR}/$AMF_BIND_ADDR/g" \
    -e "s/\${AMF_ADDR}/$AMF_ADDR/g" \
    -e "s/\${E2_ADDR}/$E2_ADDR/g" \
    < /gnb-template.yml > /gnb.yml


echo N | tee /sys/module/drm_kms_helper/parameters/poll >/dev/null

(
    echo "Starting turbostat monitoring..."
    TIMESTAMP=$(date -u +"%Y-%m-%d_%H-%M-%S")
    LOGFILE="/mnt/data/turbostat_output_cu_$TIMESTAMP.txt"
    INTERVAL=5

    turbostat --interval "$INTERVAL" | while IFS= read -r line; do
        if [[ "$line" =~ ^\ *- ]]; then
            UTC_TIME=$(date -u +"%Y-%m-%d %H:%M:%S")
            echo "[$UTC_TIME UTC]" >> "$LOGFILE"
        fi
        echo "$line" >> "$LOGFILE"
    done
) &
stdbuf -oL -eL /usr/local/bin/srscu -c /gnb.yml
