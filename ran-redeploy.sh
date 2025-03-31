#/bin/bash
helm uninstall srsran-5g
git pull
helm install srsran-5g charts/srsran-5g

