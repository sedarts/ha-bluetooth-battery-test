#!/usr/bin/env python3
"""Linux-only bounded child supervisor. No Bluetooth protocol knowledge."""
import ctypes
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def identity(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return None if fields[0] == "Z" else fields[19]
    except (OSError, IndexError):
        return None


def main():
    # Reset dispositions before launching the background manager from run.sh.
    if sys.argv[1] == "exec":
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_DFL)
        os.execvp(sys.argv[2], sys.argv[2:])
    owner, seconds, stop = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
    command = sys.argv[4:]
    owner_id = identity(owner)
    if not owner_id or (stop and Path(stop).exists()):
        return 125
    # Adopt grandchildren so an exiting command cannot leave zombies behind.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
    aborted = [False]
    def abort(_sig, _frame):
        aborted[0] = True
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, abort)
    ticket = Path(stop).parent / f"child-{os.getpid()}" if stop else None
    if ticket:
        ticket.touch()
    try:
        if aborted[0] or identity(owner) != owner_id or (stop and Path(stop).exists()):
            return 125
        return run_child(command, owner, owner_id, seconds, stop, aborted)
    finally:
        if ticket:
            ticket.unlink(missing_ok=True)
            if identity(owner) != owner_id:
                # The directory was created privately by the manager. Remove
                # it only when empty; never recursively delete another run.
                try:
                    Path(stop).unlink(missing_ok=True)
                    ticket.parent.rmdir()
                except OSError:
                    pass


def run_child(command, owner, owner_id, seconds, stop, aborted):
    deadline = time.monotonic() + seconds
    child = subprocess.Popen(command, start_new_session=True, close_fds=True)
    ended = None
    result = 125
    try:
        print(f"bluetooth-process: start pid={child.pid} owner={owner} limit={seconds}s", file=sys.stderr)
        while True:
            # WNOWAIT reserves the leader PID until group cleanup is complete;
            # this prevents a reused PID/group being signalled by late cleanup.
            ended = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if ended is not None:
                result = ended.si_status if ended.si_code == os.CLD_EXITED else 128 + ended.si_status
                break
            if aborted[0] or identity(owner) != owner_id or (stop and Path(stop).exists()):
                result = 125
                print(f"bluetooth-process: abort pid={child.pid}; stop/signal/owner-ended", file=sys.stderr)
                break
            if time.monotonic() >= deadline:
                result = 124
                print(f"bluetooth-process: timeout pid={child.pid}", file=sys.stderr)
                break
            time.sleep(.05)
    finally:
        # Only our own session/process group, never a device-wide cleanup.
        for sig, grace in ((signal.SIGTERM, .5 if ended is None else 0), (signal.SIGKILL, 0)):
            try:
                os.killpg(child.pid, sig)
            except ProcessLookupError:
                pass
            if grace:
                time.sleep(grace)
        child.wait()
        # Adopted descendants also include children that changed session. Only
        # direct, unreaped children of this supervisor are eligible for a kill.
        while True:
            children = Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()
            if not children:
                break
            for pid in map(int, children):
                try:
                    os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                except (ChildProcessError, ProcessLookupError):
                    pass
        print(f"bluetooth-process: reaped pid={child.pid} status={result}", file=sys.stderr)
    return result


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"bluetooth-process: {error}", file=sys.stderr)
        sys.exit(125)
