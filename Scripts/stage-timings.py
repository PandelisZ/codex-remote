#!/usr/bin/env python3
"""Per-stage provisioning timings, read from the app's own log.

    Scripts/stage-timings.py [machine-name]

Every stage publishes a line through Log.shared with an ISO timestamp, so the log is
already a trace of a provision; this just turns it into durations. Used to find where the
time actually goes rather than guessing — the answer has twice now been something nobody
would have picked (87s installing Node for an agent that no longer needs it).
"""
import re
import sys
import pathlib
from datetime import datetime

LOG = pathlib.Path.home() / ".codex-remote/logs/codex-remote.log"
name = sys.argv[1] if len(sys.argv) > 1 else None

line_re = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+\w+\s+\[provision\]\s+(\S+):\s+(.*)$")

events = []
for raw in LOG.read_text(errors="replace").splitlines():
    m = line_re.match(raw)
    if not m:
        continue
    when, machine, message = m.groups()
    if name and machine != name:
        continue
    events.append((datetime.strptime(when, "%Y-%m-%dT%H:%M:%SZ"), machine, message))

if not events:
    print(f"no provisioning events{' for ' + name if name else ''} in {LOG}")
    raise SystemExit(1)

# Only the most recent run. Repairs and retries append to the same log, and a fixed window
# merges them into one nonsense trace, so runs are split where the log goes quiet: no
# provisioning step legitimately takes five minutes without saying anything.
GAP = 300
run = [events[-1]]
for earlier, later in zip(reversed(events[:-1]), reversed(events[1:])):
    if (later[0] - earlier[0]).total_seconds() > GAP:
        break
    run.insert(0, earlier)

print(f"{'elapsed':>8}  {'step':>6}  message")
print("-" * 78)
start = run[0][0]
for i, (when, _machine, message) in enumerate(run):
    step = (when - run[i - 1][0]).total_seconds() if i else 0
    print(f"{(when - start).total_seconds():>7.0f}s  {step:>5.0f}s  {message[:60]}")

steps = [((run[i][0] - run[i - 1][0]).total_seconds(), run[i][2]) for i in range(1, len(run))]
steps.sort(reverse=True)
print("-" * 78)
print(f"total {(run[-1][0] - start).total_seconds():.0f}s")
print("slowest steps:")
for seconds, message in steps[:5]:
    print(f"  {seconds:>5.0f}s  {message[:60]}")
