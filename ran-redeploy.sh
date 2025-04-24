#/bin/bash
helm uninstall srsran-5g-cu
helm uninstall srsran-5g-du
git pull
helm install srsran-5g-cu charts/srsran-5g-cu
helm install srsran-5g-du charts/srsran-5g-du

