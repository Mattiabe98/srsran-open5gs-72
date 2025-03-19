#/bin/bash
helm uninstall open5gs
helm uninstall srsran-gnb
helm uninstall srsran-ue
sleep 1
git pull
helm install open5gs charts/open5gs
sleep 40
helm install srsran-gnb charts/srsran-5g-zmq
sleep 5
helm install srsran-ue charts/srsran-ue

