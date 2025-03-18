#!/bin/bash

set -ex

if [[ ! -z "$AMF_HOSTNAME" ]] ; then 
    export AMF_ADDR="$(host -4 $AMF_HOSTNAME |awk '/has.*address/{print $NF; exit}')"
fi

if [[ -z "${AMF_BIND_ADDR}" ]] ; then
    export AMF_BIND_ADDR=$(ip addr show $AMF_BIND_INTERFACE | grep -Po 'inet \K[\d.]+')
fi

sed -e "s/\${AMF_ADDR}/$AMF_ADDR/g" \
    -e "s/\${AMF_BIND_ADDR}/$AMF_BIND_ADDR/g" \
    > gnb.yml

/usr/local/bin/gnb -c gnb.yml
