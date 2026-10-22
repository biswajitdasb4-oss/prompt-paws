#!/usr/bin/env python3
"""Measure Prompt Paws's real CPU cost per state.

Starts `Prompt Paws --bench`, finds the WebKit helper processes it starts (WebContent, GPU,
Networking), and reads each process's total CPU time at every "BENCH <phase>" log line.
CPU % = CPU seconds used in the phase / wall seconds (100% = one full core; this Mac has 2 cores).
    python3 tools/measure.py [path/to/Prompt Paws.app] [--character <folder>]
"""
import os
import re
import subprocess
import sys
import time

APP = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "build/Prompt Paws.app"
EXTRA = [a for a in sys.argv[1:] if a != APP]   # passed on to Prompt Paws, e.g. --character panda
LOG = os.path.expanduser("~/.promptpaws/promptpaws.log")
WEBKIT = re.compile(r"com\.apple\.WebKit\.(WebContent|GPU|Networking)")


def processes():
    out = subprocess.run(["ps", "-Ao", "pid=,time=,command="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            rows[int(parts[0])] = (parts[1], parts[2])
    return rows


def seconds(t):
    """ps TIME like 1:02.34 or 1:02:03 -> seconds."""
    total = 0.0
    for part in t.replace("-", ":").split(":"):
        total = total * 60 + float(part)
    return total


def label(cmd):
    m = WEBKIT.search(cmd)
    return f"WebKit {m.group(1)}" if m else ("Prompt Paws" if "Prompt Paws" in cmd else ("WindowServer" if "WindowServer" in cmd else cmd[:30]))


before = {pid for pid, (_, cmd) in processes().items() if WEBKIT.search(cmd)}
log_start = os.path.getsize(LOG) if os.path.exists(LOG) else 0
app = subprocess.Popen([os.path.join(APP, "Contents/MacOS/PromptPaws"), "--bench"] + EXTRA,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

seen_phases = []
samples = []   # (phase, wall time, {pid: cpu seconds})
watch = None
names = {}
while app.poll() is None:
    time.sleep(0.5)
    with open(LOG) as f:
        f.seek(log_start)
        phases = re.findall(r"BENCH (\w+)", f.read())
    for phase in phases[len(seen_phases):]:
        seen_phases.append(phase)
        rows = processes()
        if watch is None:
            watch = [app.pid] + [pid for pid, (_, cmd) in rows.items() if WEBKIT.search(cmd) and pid not in before]
            watch += [pid for pid, (_, cmd) in rows.items() if cmd.endswith("WindowServer -daemon")]
            names = {pid: label(rows[pid][1]) for pid in watch if pid in rows}
            names[app.pid] = "Prompt Paws"
        samples.append((phase, time.time(), {pid: seconds(rows[pid][0]) for pid in watch if pid in rows}))
        print(f"  {phase} ...", flush=True)

print("\nCPU per state (100% = one core; WindowServer also serves every other app):")
header = f"{'state':<8} " + " ".join(f"{names.get(p, str(p)):>18}" for p in watch) + f" {'Prompt Paws total':>14}"
print(header)
for (phase, t0, a), (_, t1, b) in zip(samples, samples[1:]):
    wall = t1 - t0
    cells = []
    total = 0.0
    for pid in watch:
        pct = (b.get(pid, 0) - a.get(pid, 0)) / wall * 100
        cells.append(f"{pct:>17.1f}%")
        if names.get(pid) != "WindowServer":
            total += pct
    print(f"{phase:<8} " + " ".join(cells) + f" {total:>13.1f}%")
