#/bin/bash
helm uninstall open5gs
helm uninstall srsran-5g
helm uninstall linuxptp
helm uninstall influxdb2
helm uninstall grafana-srsran
git pull
