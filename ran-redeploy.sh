#/bin/bash
helm uninstall srsran-cu
helm uninstall srsran-du
git pull
helm install srsran-cu charts/srsran-5g-cu
sleep 10
helm install srsran-du charts/srsran-5g-du

