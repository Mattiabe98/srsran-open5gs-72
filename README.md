# srsRAN 7.2 + Open5Gs multi-tenant deployment
This repository will help you in deploying a **single core, multi-tenant, CU/DU split, neutral host O-RAN compliant** setup for 4 tenants.

## How to use the repository:
First of all, since this is a 7.2 split deployment, PTP synchronization is needed. The linuxptp chart can help you get started, but it needs to be edited with your PTP configuration.

The repository contains some simple yet useful Bash scripts that help you get up and running quickly. The scripts are especially useful when debugging issues that require a whole setup reboot.
The script redeploy.sh does the following:
- Uninstalls any previous deployments of this repo, to start with a clean state
- Pulls the latest version of this repository
- Builds dependencies
- Installs:
  - Open5Gs
  - InfluxDB
  - Grafana srsRAN monitoring stack

Once the script is done, everything is ready, except the RAN.
The next script to run is ran-redeploy-all.sh, which does the following:
-  Pulls the latest version of this repository
-  Uninstalls any previous RAN deployments of this repo (CU and DUs)
-  Installs:
  - one srsRAN CU
  - 4 srsRAN DUs

Two other scripts are present, to uninstall partially or completely the deployment:
- uninstall-ran.sh: as the name says, uninstalls CU/DUs.
- uninstall-all.sh: uninstalls the whole deployment of this repository.

## How to edit this repository:
The most crucial files in this repository are the Open5GS values.yaml file, which contains the whole core setup (subnets, APNs, slices) and subscriber infos (IMSI and APNs), and the srsRAN CU/DUs gnb-template.yaml files, which contain the configuration of CU, DUs and O-RUs. Those files need to match the configuration of the core, especially regarding PLMNs and IPs. The DU gnb-template.yaml files also need to match the O-RU configuration or the fronthaul will NOT work. MAC addresses, VLANs, eAxc IDs, DPDK PCI addresses are especially important.

Some resources to help you get started:

srsRAN configuration (gnb-template.yaml) reference: https://docs.srsran.com/projects/project/en/latest/user_manuals/source/config_ref.html

srsRAN O-RAN 7.2 RU guide: https://docs.srsran.com/projects/project/en/latest/tutorials/source/oranRU/source/index.html

srsRAN DPDK tutorial: https://docs.srsran.com/projects/project/en/latest/tutorials/source/dpdk/source/index.html

## Additional scripts/tools

By default, the DU0 (srsran-5g-du) will also run a turbostat-like monitoring Python script that gathers metrics on all CPU cores and the whole CPU package; this can be very useful to see which threads are the most constrained and how to best allocate the srsRAN threads. The script saves its results to /mnt/data/monitoring, so be sure to create a PV/PVC mountpoint if you want the script to work.
Example output:

--- 2025-05-29 17:41:11 UTC ---
Core    CPU      ActMHz Avg_MHz Busy%   Bzy_MHz TSC_MHz        IRQ      POLL%     C1%    C1E%     C6%   CoreTmp CoreThr  PkgTmp MinMHz  MaxMHz     Governor     EPB     PkgWatt RAMWatt
0       0        2900.0  1058.4 36.41    2907.2  2192.5      98419       0.02    0.53   63.57    0.82        50       N      52  800    3500    performance       0      100.94    9.60
1       1        2843.0  1006.0 35.57    2828.3  2188.9      95681       0.02    0.58   63.37    1.50        50       N      52  800    3500    performance       0      100.94    9.60
2       2        2400.0   899.8 36.18    2487.2  2184.2      92719       0.02    0.63   61.91    2.18        45       N      52  800    3500    performance       0      100.94    9.60
3       3        2188.0   835.5 36.49    2289.6  2186.7      97413       0.02    0.57   61.15    2.84        47       N      52  800    3500    performance       0      100.94    9.60
4       4        2800.0   402.2 14.17    2838.9  2189.3     129657       0.06    0.11   86.75    0.00        48       N      52  800    3500    performance       0      100.94    9.60
5       5        3000.0  2793.9 98.16    2846.2  2190.9    1629558       0.00    6.25    0.69    0.00        49       N      52  800    3500    performance       0      100.94    9.60
6       6        3100.0     5.4  0.18    2916.2  2191.3        620       0.00    0.02    0.69   98.95        53       N      52  800    3500    performance       0      100.94    9.60
7       7        2800.0    41.9  1.47    2852.1  2191.4        907       0.00    0.00    1.39   97.04        49       N      52  800    3500    performance       0      100.94    9.60
8       8        2885.6    65.7  2.32    2829.4  2191.5        633       0.00    0.00    0.56   96.99        48       N      52  800    3500    performance       0      100.94    9.60
9       9        3000.0  2739.2 96.25    2845.9  2191.1    1543173       0.00   11.92    2.55    0.00        50       N      52  800    3500    performance       0      100.94    9.60
10      10       3000.0     4.0  0.14    2810.4  2192.6        367       0.00    0.00    0.62   99.22        49       N      52  800    3500    performance       0      100.94    9.60
11      11       2797.5    41.6  1.49    2794.0  2194.0       1703       0.00    0.00    1.48   96.93        48       N      52  800    3500    performance       0      100.94    9.60
12      12       2856.9    66.5  2.38    2799.2  2189.2        610       0.00    0.00    0.33   96.75        50       N      52  800    3500    performance       0      100.94    9.60
13      13       2800.0  2728.8 96.32    2833.1  2179.9    1546103       0.00   11.57    2.32    0.00        50       N      52  800    3500    performance       0      100.94    9.60
14      14       2800.1     7.7  0.31    2469.1  2170.5       2060       0.00    0.00    0.55   97.86        49       N      52  800    3500    performance       0      100.94    9.60
15      15       2600.0    41.1  1.63    2517.6  2163.1       2397       0.00    0.00    1.19   95.87        46       N      52  800    3500    performance       0      100.94    9.60
16      16       2401.0    68.5  2.72    2521.0  2161.3       2266       0.00    0.01    0.37   95.19        47       N      52  800    3500    performance       0      100.94    9.60
17      17       2800.0  2693.7 96.28    2797.9  2154.1    1536311       0.00   11.40    2.37    0.00        48       N      52  800    3500    performance       0      100.94    9.60
18      18       2600.3     3.7  0.17    2204.5  2157.8        408       0.00    0.00    0.54   97.47        46       N      52  800    3500    performance       0      100.94    9.60
19      19       2200.0    37.0  1.59    2322.2  2149.1       1374       0.00    0.00    1.27   95.02        46       N      52  800    3500    performance       0      100.94    9.60
20      20       2652.6    65.3  2.82    2316.7  2143.7        622       0.00    0.01    0.30   94.23        49       N      52  800    3500    performance       0      100.94    9.60
21      21       2899.9     4.4  0.15    2858.8  2130.4        553       0.00    0.06    0.28   96.14        47       N      52  800    3500    performance       0      100.94    9.60
22      22       2800.1     6.2  0.30    2045.3  2116.3        370       0.00    0.00    0.49   95.39        45       N      52  800    3500    performance       0      100.94    9.60
23      23       2300.0     6.6  0.29    2269.2  2106.7       5196       0.00    0.03    0.25   94.97        45       N      52  800    3500    performance       0      100.94    9.60
24      24       2700.0     3.7  0.16    2238.7  2092.9        635       0.00    0.00    0.47   94.68        45       N      52  800    3500    performance       0      100.94    9.60
25      25       2400.0     2.6  0.11    2363.0  2087.8        253       0.00    0.01    0.28   94.29        44       N      52  800    3500    performance       0      100.94    9.60
26      26       2900.0     3.1  0.11    2825.0  2074.8        226       0.00    0.00    0.47   93.69        47       N      52  800    3500    performance       0      100.94    9.60
27      27       2500.0     2.7  0.11    2378.7  2065.9        298       0.00    0.02    0.22   93.27        46       N      52  800    3500    performance       0      100.94    9.60
28      28       2300.0     3.2  0.15    2167.6  2052.8        946       0.00    0.00    0.35   93.03        44       N      52  800    3500    performance       0      100.94    9.60
29      29       2500.0     2.4  0.10    2442.1  2051.1        252       0.00    0.00    0.29   92.88        43       N      52  800    3500    performance       0      100.94    9.60
30      30       2895.8     2.6  0.10    2673.2  2044.2        240       0.00    0.00    0.39   92.67        44       N      52  800    3500    performance       0      100.94    9.60
31      31       2900.0     3.1  0.12    2716.9  2042.7        408       0.00    0.01    0.37   92.29        43       N      52  800    3500    performance       0      100.94    9.60
0       32       3100.0   420.5 15.50    2713.8  2035.7     118361       0.03    0.04   79.17    0.00        50       N      52  800    3500    performance       0      100.94    9.60
1       33       2900.1   416.6 15.69    2655.7  2034.4     119149       0.04    0.05   78.75    0.00        50       N      52  800    3500    performance       0      100.94    9.60
2       34       2900.0   388.8 16.38    2374.4  2025.7     117836       0.03    0.05   78.06    0.00        45       N      52  800    3500    performance       0      100.94    9.60
3       35       2500.0   375.1 17.08    2196.5  2024.3     117268       0.04    0.04   77.03    0.00        47       N      52  800    3500    performance       0      100.94    9.60
4       36       2800.0   280.1 10.71    2616.2  2014.7     124291       0.02    0.06   82.43    0.00        48       N      52  800    3500    performance       0      100.94    9.60
5       37       2800.0     1.5  0.06    2686.1  2004.5         44       0.00    0.05    0.08   91.11        49       N      52  800    3500    performance       0      100.94    9.60
6       38       2917.1  2257.7 84.35    2676.7  2003.7    1131304       0.00   25.16   12.07    0.00        53       N      52  800    3500    performance       0      100.94    9.60
7       39       2800.0  1630.5 62.75    2598.5  2000.7     875333       0.00    4.91   37.58    0.00        49       N      52  800    3500    performance       0      100.94    9.60
8       40       2800.0  1786.8 69.13    2584.8  1988.6     728949       0.00    0.93   31.48    0.00        48       N      52  800    3500    performance       0      100.94    9.60
9       41       3000.0     2.5  0.09    2771.7  1983.6        168       0.00    0.01    0.16   89.95        50       N      52  800    3500    performance       0      100.94    9.60
10      42       2800.0  2182.3 84.17    2592.8  1978.8    1136078       0.00   25.30   11.39    0.00        49       N      52  800    3500    performance       0      100.94    9.60
11      43       2800.0  1591.0 63.06    2523.2  1974.6     872656       0.00    5.13   37.17    0.00        48       N      52  800    3500    performance       0      100.94    9.60
12      44       2800.0  1756.3 69.06    2543.1  1983.0     727216       0.00    0.93   31.45    0.00        50       N      52  800    3500    performance       0      100.94    9.60
13      45       2886.8     2.5  0.09    2819.4  1977.2        170       0.00    0.02    0.13   89.52        50       N      52  800    3500    performance       0      100.94    9.60
14      46       2900.0  1984.6 85.53    2320.3  1968.6    1103029       0.00   24.60   10.87    0.00        49       N      52  800    3500    performance       0      100.94    9.60
15      47       2600.0  1481.0 64.37    2300.8  1966.2     859037       0.00    5.51   35.81    0.00        46       N      52  800    3500    performance       0      100.94    9.60
16      48       2800.0  1619.8 70.32    2303.4  1965.6     706636       0.00    0.85   30.35    0.00        47       N      52  800    3500    performance       0      100.94    9.60
17      49       2800.0     2.0  0.08    2516.9  1966.7         80       0.00    0.00    0.23   89.43        48       N      52  800    3500    performance       0      100.94    9.60
18      50       2700.0  1863.7 86.69    2149.9  1969.0    1051785       0.00   23.40   10.78    0.00        46       N      52  800    3500    performance       0      100.94    9.60
19      51       2600.0  1385.1 64.92    2133.6  1965.4     849423       0.00    5.59   35.11    0.00        46       N      52  800    3500    performance       0      100.94    9.60
20      52       2900.0  1518.0 71.17    2132.9  1960.3     692140       0.00    0.84   29.19    0.00        49       N      52  800    3500    performance       0      100.94    9.60
21      53       2900.0    12.8  0.62    2059.7  1952.7      18445       0.00    0.01    0.15   88.13        47       N      52  800    3500    performance       0      100.94    9.60
22      54       2400.0     1.8  0.08    2169.6  1947.8        125       0.00    0.02    0.19   88.44        45       N      52  800    3500    performance       0      100.94    9.60
23      55       2800.1     3.6  0.17    2156.4  1947.1        787       0.00    0.00    0.27   88.22        45       N      52  800    3500    performance       0      100.94    9.60
24      56       2600.0    19.3  1.05    1832.7  1944.6      23021       0.00    0.01    0.18   87.45        45       N      52  800    3500    performance       0      100.94    9.60
25      57       2695.8     1.9  0.08    2381.3  1942.1        145       0.00    0.00    0.24   88.11        44       N      52  800    3500    performance       0      100.94    9.60
26      58       2900.6     2.8  0.11    2564.7  1940.9        413       0.00    0.00    0.24   87.94        47       N      52  800    3500    performance       0      100.94    9.60
27      59       2700.0     1.6  0.08    2177.4  1936.4        196       0.00    0.00    0.30   87.99        46       N      52  800    3500    performance       0      100.94    9.60
28      60       2601.8     1.8  0.08    2147.0  1939.1        125       0.00    0.01    0.25   88.06        44       N      52  800    3500    performance       0      100.94    9.60
29      61       2500.0     2.3  0.10    2367.7  1939.0        426       0.00    0.00    0.23   87.77        43       N      52  800    3500    performance       0      100.94    9.60
30      62       2900.0     1.7  0.07    2364.2  1932.8         78       0.00    0.00    0.34   87.85        44       N      52  800    3500    performance       0      100.94    9.60
31      63       2900.3     1.9  0.08    2264.6  1937.2        185       0.00    0.00    0.33   88.09        43       N      52  800    3500    performance       0      100.94    9.60

On the UPF there are also some benchmarking scripts, useful to test the throughput in a multi-tenant scenario, with multiple UEs:

  -  iperf3-test.sh: runs an array of multiple iPerf3 tests, such as: UDP/TCP, single/parallel streams, uncapped/capped, constant/burst, uplink/downlink/bidirectional.

To use the script, on the UPF run /iperf3-test.sh <list of IPs:port iPerf3 servers> <number of runs>
  -  iperf3-latency.sh: runs a continious ping in different scenarios, such as: idle, iPerf3 on one UE, iPerf3 on all UEs, iPerf3 on all UEs except one, and more.

To use the script, on the UPF run /iperf3-latency.sh <list of IPs:port iPerf3 servers>


# Gradiant 5G Charts

This repo mantains helm charts generated by [Gradiant](https://www.gradiant.org) for its Lab5G platform.

Gradiant is actively researching and developing Cloud-Native Network Functions (CNFs) with special focus on 5G network and evolvable to 6G technologies.

Follow the README.md of each chart to evaluate the technologies in your kubernetes cluster.

## Install chart from DockerHub repository

charts in `charts/`` folder are packaged and available at Gradiant's DockerHub repo:  

[https://hub.docker.com/u/gradiant](https://hub.docker.com/u/gradiant)

You can pull and save locally the chart. For example:

```bash
helm pull oci://registry-1.docker.io/gradiant/open5gs --version 2.2.0
```

You can directly install the chart. For example, to install open5gs:

```bash
helm install open5gs oci://registry-1.docker.io/gradiant/open5gs --version 2.2.0
```

## Check out our tutorials

We have developed some tutorials meant to **guide you through the combined deployment of different technologies**. It is an easy and quick way of testing these technologies and exploring how they work.

These tutorials make use of charts available at this repo, and their corresponding documentation can be found at:
[https://gradiant.github.io/5g-charts/](https://gradiant.github.io/5g-charts/)

## Development

- clone repo
- adjust given chart
- bump chart version if required
- run tests
- create pull request with issue id, attach test results if possible

### Requirements

- linting requires docker
- running test-install.sh requires docker and kubernetes-in-docker.
- `tee` console tool to output to the console and file in the same time

## Linting and testing full deployment

We use helm [chart-testing](https://github.com/helm/chart-testing) running a docker image.

An example to test specific chart lint and install, send console logs also to the log file `reports/*.log`:

```bash
scripts/lint-install.sh open5gs | tee reports/open5gs.log
```
