#/bin/bash
git pull
helm uninstall srsran-5g-cu
helm uninstall srsran-5g-du
helm uninstall srsran-5g-du-1
helm uninstall srsran-5g-du-2
helm uninstall srsran-5g-du-3
helm uninstall srsran-5g-du-4
helm uninstall srsran-5g-du-5

sleep 5
helm install srsran-5g-cu charts/srsran-5g-cu
sleep 1
helm install srsran-5g-du charts/srsran-5g-du
sleep 1
helm install srsran-5g-du-1 charts/srsran-5g-du-1
sleep 1
helm install srsran-5g-du-2 charts/srsran-5g-du-2
sleep 1
helm install srsran-5g-du-3 charts/srsran-5g-du-3
sleep 1
helm install srsran-5g-du-4 charts/srsran-5g-du-4
sleep 1
helm install srsran-5g-du-5 charts/srsran-5g-du-5
