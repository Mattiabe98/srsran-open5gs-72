helm uninstall srsran-5g-cu srsran-5g-du
cd /root/helm-oran-sc-ric
./restart-ric.sh
cd /root/srsran-open5gs-72
./ran-redeploy.sh
