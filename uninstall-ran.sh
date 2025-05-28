#/bin/bash
git pull
helm uninstall srsran-5g-cu
helm uninstall srsran-5g-du
helm uninstall srsran-5g-du-1
helm uninstall srsran-5g-du-2
helm uninstall srsran-5g-du-3
helm uninstall srsran-5g-du-4
helm uninstall srsran-5g-du-5

