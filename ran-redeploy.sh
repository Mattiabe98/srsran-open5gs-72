#/bin/bash
git pull
helm uninstall srsran-5g-cu
helm uninstall srsran-5g-du-2
helm install srsran-5g-cu charts/srsran-5g-cu
helm install srsran-5g-du-2 charts/srsran-5g-du-2
