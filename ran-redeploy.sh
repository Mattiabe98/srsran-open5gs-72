#/bin/bash
helm uninstall srsran-gnb
helm uninstall srsran-ue
sleep 1
git pull
helm install srsran-gnb charts/srsran-5g-zmq
sleep 5
helm install srsran-ue charts/srsran-ue

