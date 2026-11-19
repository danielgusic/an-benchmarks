import matplotlib.pyplot as plt
import time
from pathlib import Path
import subprocess
import sys
import json

HERE = Path.cwd()
ROOT = Path.cwd().parent.parent
wasmtime = ROOT / "deps/wasmtime-an/target/release/wasmtime"
crc32_off = HERE / "build/crc_32.off.cwasm"
crc32_an = HERE / "build/crc_32.an.cwasm"
datafile = ROOT / "deps/mibench/telecomm/adpcm/data/large.pcm"
reps = 100

def run_experiment(wasmtime, crc32, enable_an, datafile, reps=1000):
    results = []
    an = "y" if enable_an else "n"
    for i in range(reps):
        start = time.perf_counter_ns()
        subprocess.run([wasmtime, "run", "--dir=/", "--allow-precompiled", "-C", "cache=n", "-C", f"an-encoding={an}", crc32, datafile])
        after = time.perf_counter_ns()
        results.append(after - start)
    return results

def measure(out):
    res_an_off = run_experiment(wasmtime, crc32_off, False, datafile, reps)
    res_an_on = run_experiment(wasmtime, crc32_an, True, datafile, reps)
    with open(out, "w+") as fp:
        json.dump({"off": res_an_off, "an": res_an_on}, fp)

def plot(inf, out):
    with open(inf) as fp:
        results = json.load(fp)
    fig, ax = plt.subplots()
    ax.plot(range(1, max_n + 1), res_an_off, label="Without Encoding")
    ax.plot(range(1, max_n + 1), res_an_on, label="With Encoding")
    ax.legend()
    ax.set(xlabel="Fibonacci Input", ylabel="Execution time (ns)")

    fig.savefig(out, format="pdf")

if sys.argv[1] == "measure":
    measure(sys.argv[2])
elif sys.argv[1] == "plot":
    plot(sys.argv[2], sys.argv[3])
else:
    print("Unknown command")
