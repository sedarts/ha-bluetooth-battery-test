#!/usr/bin/env python3
"""Linux-only bounded child supervisor. No Bluetooth protocol knowledge."""
import ctypes
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

PROC_ROOT = Path("/proc")
CLEANUP_SECONDS = 2.0


def process_record(pid, proc_root=PROC_ROOT):
    try:
        fields = (proc_root / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
        # Fields after comm start at proc stat field 3: state, ppid, ...,
        # starttime. Keep ppid and starttime together to reject PID reuse.
        return fields[0], int(fields[1]), fields[19]
    except (OSError, IndexError, ValueError):
        return None


def identity(pid, proc_root=PROC_ROOT):
    record = process_record(pid, proc_root)
    return None if not record or record[0] == "Z" else record[2]


def direct_children(parent, proc_root=PROC_ROOT, force_scan=False):
    """Return verified direct children and whether enumeration was reliable.

    Linux may expose task/<tid>/children, but that optional procfs entry is
    absent in the deployed Alpine container and can omit racing exits. Always
    cross-check it with a /proc PPid scan; disappearing entries are normal.
    """
    children_file = proc_root / "self" / "task" / str(parent) / "children"
    records = {}
    fast_available = False
    if not force_scan:
        try:
            pids = [int(value) for value in children_file.read_text().split()]
        except (OSError, ValueError):
            pass
        else:
            fast_available = True
            for pid in pids:
                record = process_record(pid, proc_root)
                if record and record[1] == parent:
                    records[pid] = record[2]

    try:
        entries = list(proc_root.iterdir())
    except OSError:
        return sorted(records.items()), "task-children", False
    for entry in entries:
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        record = process_record(pid, proc_root)
        if record and record[1] == parent:
            records[pid] = record[2]
    source = "task-children+proc-scan" if fast_available else "proc-scan"
    return sorted(records.items()), source, True


def same_direct_child(pid, starttime, parent, proc_root=PROC_ROOT):
    record = process_record(pid, proc_root)
    return bool(record and record[1] == parent and record[2] == starttime)


def signal_owned_child(pid, starttime, parent, proc_root=PROC_ROOT):
    """Signal only the same process that was observed as our direct child."""
    if not same_direct_child(pid, starttime, parent, proc_root):
        return False
    pidfd = None
    if hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"):
        try:
            pidfd = os.pidfd_open(pid, 0)
            # Opening a pidfd pins the identity. Recheck ownership after open;
            # if the process exited/reparented, do not signal it.
            if not same_direct_child(pid, starttime, parent, proc_root):
                return False
            signal.pidfd_send_signal(pidfd, signal.SIGKILL)
            return True
        except ProcessLookupError:
            return True
        except OSError:
            pass
        finally:
            if pidfd is not None:
                os.close(pidfd)
    # Older kernels/Python: recheck immediately before the PID signal. The
    # exact PPid+starttime match prevents a stale scan result from being used.
    if not same_direct_child(pid, starttime, parent, proc_root):
        return False
    try:
        os.kill(pid, signal.SIGKILL)
        return True
    except ProcessLookupError:
        return True
    except OSError:
        return False


def reap_owned_children(deadline, proc_root=PROC_ROOT):
    parent = os.getpid()
    force_scan = os.environ.get("BT_PROCESS_FORCE_PROC_SCAN") == "1"
    scan_logged = False
    while time.monotonic() < deadline:
        children, source, reliable = direct_children(parent, proc_root, force_scan)
        if source == "proc-scan" and not scan_logged:
            print("bluetooth-process: task children unavailable; using bounded PPid scan", file=sys.stderr)
            scan_logged = True
        if not reliable:
            print("bluetooth-process: cleanup cannot enumerate owned children", file=sys.stderr)
            return False
        if not children:
            return True
        for pid, starttime in children:
            try:
                waited, _status = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    continue
            except ChildProcessError:
                continue
            signal_owned_child(pid, starttime, parent, proc_root)
        time.sleep(.02)
    children, _source, reliable = direct_children(parent, proc_root, force_scan)
    return reliable and not children


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
        cleanup_deadline = time.monotonic() + CLEANUP_SECONDS
        try:
            child.wait(timeout=max(0, cleanup_deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            result = 125
            print(f"bluetooth-process: cleanup deadline waiting for pid={child.pid}", file=sys.stderr)
        # Adopted descendants also include children that changed session. Only
        # verified direct children of this supervisor are eligible for a kill.
        # Enumeration and waiting are bounded even for kernel D-state failures.
        if not reap_owned_children(cleanup_deadline):
            result = 125
            print("bluetooth-process: cleanup deadline with owned children remaining", file=sys.stderr)
        print(f"bluetooth-process: reaped pid={child.pid} status={result}", file=sys.stderr)
    return result


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"bluetooth-process: {error}", file=sys.stderr)
        sys.exit(125)
