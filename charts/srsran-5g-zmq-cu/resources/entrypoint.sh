#!/bin/bash

# set -ex


resolve_ip() {
    python3 -c "import socket; print(socket.gethostbyname('$1'))" 2>/dev/null
}

if [[ -n "$AMF_HOSTNAME" ]]; then 
    export AMF_ADDR="$(resolve_ip "$AMF_HOSTNAME")"
fi

if [[ -n "$SRSRAN_CU_GTPU" ]]; then 
    export SRSRAN_CU_GTPU_IP="$(resolve_ip "$SRSRAN_CU_GTPU")"
fi

if [[ -n "$SRSRAN_CU_F1AP" ]]; then 
    export SRSRAN_CU_F1AP_IP="$(resolve_ip "$SRSRAN_CU_F1AP")"
fi

# Replace variables in the template
sed -e "s/\${SRSRAN-CU-GTPU}/$SRSRAN_CU_GTPU_IP/g" \
    -e "s/\${SRSRAN-CU-F1AP}/$SRSRAN_CU_F1AP_IP/g" \
    -e "s/\${AMF_ADDR}/$AMF_ADDR/g" \
    < /cu-template.yml > cu.yml
