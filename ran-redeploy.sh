#/bin/bash
helm uninstall srsran-cu
helm uninstall srsran-du
git pull
helm install srsran-cu charts/srsran-5g-cu
helm install srsran-du charts/srsran-5g-du

