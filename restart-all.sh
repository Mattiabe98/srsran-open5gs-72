echo "Cleaning namespace, uninstalling everything.."
oc project srs72
helm uninstall srsran-5g-cu
helm uninstall srsran-5g-du srsran-5g-du-1 srsran-5g-du-3 srsran-5g-du-4
helm uninstall open5gs
helm uninstall influxdb2
helm uninstall grafana-srsran
helm uninstall xapp
helm uninstall e2mgr
helm uninstall e2term
helm uninstall appmgr
helm uninstall dbaas
helm uninstall submgr
helm uninstall rtmgr-sim
helm uninstall ecoran
sleep 5

echo "Restarting RIC..."
cd /root/helm-oran-sc-ric/
/root/helm-oran-sc-ric/restart-ric.sh
echo "Restarting core and srsRAN monitoring stack..."
cd /root/srsran-open5gs-72/
/root/srsran-open5gs-72/redeploy.sh
echo "Waiting for core to go up.."
sleep 60
echo "Restarting RAN.."
/root/srsran-open5gs-72/ran-redeploy-all.sh
sleep 20
echo "Restarting ecoRAN.."
cd /root/ecoran/
/root/ecoran/redeploy.sh
