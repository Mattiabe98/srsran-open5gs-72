#!/bin/bash

# set -ex

resolve_ip() {
    python3 -c "import socket; print(socket.gethostbyname('$1'))" 2>/dev/null
}


if [[ -z "$DU_BIND_ADDR" ]] ; then
    export DU_BIND_ADDR=$(hostname -I)
fi

export CUCP_ADDRESS="$(resolve_ip "$CUCP_ADDRESS")"

# Replace variables in the template
sed -e "s/\${CUCP_ADDRESS}/$CUCP_ADDRESS/g" \
    -e "s/\${DU_BIND_ADDR}/$DU_BIND_ADDR/g" \
    < /cu-template.yml > cu.yml

/usr/local/bin/srscu -c /cu.yml
