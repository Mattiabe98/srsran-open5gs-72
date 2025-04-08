#/bin/bash
helm uninstall open5gs
helm uninstall srsran-5g
helm uninstall linuxptp
helm uninstall influxdb2
helm uninstall grafana-srsran
sleep 10
git pull
cd charts/open5gs/
helm dependency update
cd ../../
helm install open5gs charts/open5gs
#helm install linuxptp charts/linuxptp
helm install influxdb2 charts/influxdb2
helm install grafana-srsran charts/grafana-srsran
echo "Waiting for gNB and carriers"
echo "helm install srsran-5g charts/srsran-5g"
