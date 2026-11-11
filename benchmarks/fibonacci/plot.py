import matplotlib.pyplot as plt
import time
import subprocess
import json

wasmtime = "../../deps/wasmtime-an/target/release/wasmtime"
fibonacci_off = "build/fibonacci.off.cwasm"
fibonacci_an = "build/fibonacci.an.cwasm"
max_n = 35
reps = 1000000000

def run_experiment(wasmtime, fibonacci, enable_an, max_n, reps=1000000000):
    results = []
    an = "y" if enable_an else "n"
    for i in range(1, max_n + 1):
        n = str(i)
        reps = str(reps)
        start = time.perf_counter_ns()
        subprocess.run([wasmtime, "run", "--allow-precompiled", "-C", "cache=n", "-C", f"an-encoding={an}", fibonacci, n, reps])
        after = time.perf_counter_ns()
        results.append(after - start)
    return results

def measure(out):
    res_an_off = run_experiment(wasmtime, fibonacci_off, False, max_n, reps)
    res_an_on = run_experiment(wasmtime, fibonacci_an, True, max_n, reps)
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
