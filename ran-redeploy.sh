#/bin/bash
git pull
helm uninstall srsran-5g-cu
helm uninstall srsran-5g-du srsran-5g-du-1 srsran-5g-du-2 srsran-5g-du-3 srsran-5g-du-4 srsran-5g-du-5
helm install srsran-5g-cu charts/srsran-5g-cu
helm install srsran-5g-du charts/srsran-5g-du
helm install srsran-5g-du-1 charts/srsran-5g-du-1
helm install srsran-5g-du-2 charts/srsran-5g-du-2
helm install srsran-5g-du-3 charts/srsran-5g-du-3
helm install srsran-5g-du-4 charts/srsran-5g-du-4
helm install srsran-5g-du-5 charts/srsran-5g-du-5
