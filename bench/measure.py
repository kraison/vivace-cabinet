#!/usr/bin/env python3
"""measure.py OUT TIMEOUT CMD [ARG...]: run CMD, then write its wall
seconds, user and system CPU seconds, peak resident kilobytes, exit
status and whether it timed out (1 or 0) to OUT as one line.  GNU time
is not installed everywhere; wait4 gives the same numbers for exactly
this child.  CMD and its process group are killed after TIMEOUT seconds
(0: never), when this process is signalled, and when its parent dies."""
import ctypes
import os
import signal
import subprocess
import sys
import time

out, timeout, cmd = sys.argv[1], float(sys.argv[2]), sys.argv[3:]


def write(wall, user, system, rss, status, timed_out):
    with open(out, "w") as f:
        f.write("%.6f %.6f %.6f %d %d %d\n"
                % (wall, user, system, rss, status, timed_out))


try:
    # PR_SET_PDEATHSIG: SIGTERM this process when its parent dies.
    ctypes.CDLL(None).prctl(1, signal.SIGTERM)
except (OSError, AttributeError):
    pass
start = time.monotonic()
try:
    child = subprocess.Popen(cmd, start_new_session=True)
except OSError:
    # CMD cannot start: exit status 127, as a shell gives.
    write(0, 0, 0, 0, 127, 0)
    sys.exit(0)


def stop(signum, frame):
    os.killpg(child.pid, signal.SIGKILL)
    os.wait4(child.pid, 0)
    sys.exit(128 + signum)


for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(s, stop)
timed_out = 0
while True:
    pid, status, usage = os.wait4(child.pid, os.WNOHANG)
    if pid:
        break
    if timeout > 0 and time.monotonic() - start > timeout:
        os.killpg(child.pid, signal.SIGKILL)
        _, status, usage = os.wait4(child.pid, 0)
        timed_out = 1
        break
    time.sleep(0.1)
write(time.monotonic() - start, usage.ru_utime, usage.ru_stime,
      usage.ru_maxrss, os.waitstatus_to_exitcode(status), timed_out)
sys.exit(0)
