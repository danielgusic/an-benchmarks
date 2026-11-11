import matplotlib.pyplot as plt
import time
import subprocess
import sys
import json

pointoc = "target/release/point-oc-host"
network_latencies = [0, 1, 2, 5, 10]
n_telegrams = 1000

def run_experiment(pointoc, enable_an, n_telegrams, net_latency=0, reps=5):
    results = []
    n = str(n_telegrams)
    an = ["--an"] if enable_an else []
    net_delay = ["--network-latency-us", str(net_latency)] if net_latency != 0 else []
    for i in range(reps):
        start = time.perf_counter_ns()
        cmd = [pointoc, *an, "--bench", n, *net_delay]
        print("---\n{0}\n---".format(" ".join(cmd)))
        subprocess.run(cmd)
        after = time.perf_counter_ns()
        results.append(after - start)
    return sum(results) / reps

def measure(out):
    # network_latencies = [0, 1]
    results = {"off": [], "an": []}
    for nd in network_latencies:
        res_an_off = run_experiment(pointoc, False, n_telegrams, nd * 1000)
        res_an_on = run_experiment(pointoc, True, n_telegrams, nd * 1000)
        results["off"].append(res_an_off / 1000000000)
        results["an"].append(res_an_on / 1000000000)
    with open(out, "w+") as fp:
        json.dump(results, fp)

def plot(inf, out):
    with open(inf) as fp:
        results = json.load(fp)
    fig, ax = plt.subplots()
    res = ax.grouped_bar(results, tick_labels=network_latencies, group_spacing=0.2)
    for container in res.bar_containers:
        ax.bar_label(container,  fmt="%.2f")
    ax.legend(["Without Encoding", "With Encoding"])
    ax.set(xlabel="Network Latency (ms)", ylabel="Execution time (s)")

    fig.savefig(out, format="pdf")
    

if sys.argv[1] == "measure":
    measure(sys.argv[2])
elif sys.argv[1] == "plot":
    plot(sys.argv[2], sys.argv[3])
else:
    print("Unknown command")
    

