#!/usr/bin/env python3
"""measure.py OUT CMD [ARG...]: run CMD, then write its wall seconds,
user and system CPU seconds, peak resident kilobytes and exit status to
OUT as one line.  GNU time is not installed everywhere; wait4 gives the
same numbers for exactly this child."""
import os
import subprocess
import sys
import time

out, cmd = sys.argv[1], sys.argv[2:]
start = time.monotonic()
try:
    child = subprocess.Popen(cmd)
except OSError:
    # CMD cannot start: exit status 127, as a shell gives.
    with open(out, "w") as f:
        f.write("0 0 0 0 127\n")
    sys.exit(0)
_, status, usage = os.wait4(child.pid, 0)
wall = time.monotonic() - start
with open(out, "w") as f:
    f.write("%.6f %.6f %.6f %d %d\n" % (wall, usage.ru_utime, usage.ru_stime,
                                       usage.ru_maxrss,
                                       os.waitstatus_to_exitcode(status)))
sys.exit(0)
