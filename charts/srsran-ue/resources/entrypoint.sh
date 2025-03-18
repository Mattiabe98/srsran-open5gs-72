#!/bin/bash

# set -ex

resolve_ip() {
    python3 -c "import socket; print(socket.gethostbyname('$1'))" 2>/dev/null
}


if [[ -z "$DU_BIND_ADDR" ]] ; then
    export DU_BIND_ADDR=$(hostname -I)
fi

export CU_ADDR="$(resolve_ip "$CU_ADDRESS")"
export METRICS_ADDR="$(resolve_ip "$METRICS_ADDRESS")"

# Replace variables in the template
sed -e "s/\${CU_ADDR}/$CU_ADDR/g" \
    -e "s/\${DU_BIND_ADDR}/$DU_BIND_ADDR/g" \
    -e "s/\${METRICS_ADDR}/$METRICS_ADDR/g" \
    < /du-template.yml > du.yml

/usr/local/bin/srsdu -c /du.yml
