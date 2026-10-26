#!/usr/bin/env python3
"""Linux release gate, fake Bluetooth only. No network, hardware or privileges.

Run: python3 tests/linux-process-lifecycle.py -v
Requires Linux /proc, Python 3, bash, flock. Run again inside the target Alpine
image. The real Python supervisor is used, not a timeout mock. Failures are real
gate failures, not expectedFailure. The current implementation is not certified.
"""
import os
from pathlib import Path
import importlib.util
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LINUX = sys.platform.startswith("linux") and Path("/proc/self/fd").exists()
SPEC = importlib.util.spec_from_file_location("bluetooth_process", ROOT / "lib/bluetooth-process.py")
PROCESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROCESS)

# This fixture replaces only Bluetooth/audio/MQTT executables. Real bash,
# timeout, signals, /proc and flock remain in use. It deliberately ignores TERM
# and INT while hanging, so timeout escalation is exercised, not just exit 143.
FAKE = r'''
import os, pathlib, signal, sys, time
name = pathlib.Path(sys.argv[0]).name
base = pathlib.Path(os.environ["LIFECYCLE_TMP"])
stage = os.environ["LIFECYCLE_STAGE"]
args = sys.argv[1:]
with (base / "calls").open("a") as log:
    log.write(name + " " + " ".join(args) + "\n")
hang = ((name == "gatttool" and stage in ("gatt", "tree")) or
        (name == "bluetoothctl" and args[:1] == ["info"] and stage == "info"))
if hang:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    if stage == "tree" and os.fork() == 0:
        os.setsid()
        (base / "grandchild").write_text(str(os.getpid()))
        time.sleep(120)
        sys.exit(0)
    (base / "worker").write_text(str(os.getpid()))
    time.sleep(120)
elif name == "bluetoothctl" and args[:1] == ["info"]:
    print("Connected: yes" if stage == "unknown-owner" else "Connected: no")
elif name == "gatttool" and stage == "busy":
    print("connect: Resource busy (16)")
    sys.exit(1)
elif name == "mosquitto_sub":
    marker = base / "sent"
    again = base / "new-wake"
    if not marker.exists() or again.exists():
        marker.touch()
        again.unlink(missing_ok=True)
        print("bluetooth_audio_bridge/c0288d82f7bb/power/command wake")
    else:
        time.sleep(.05)
'''


class ProcEnumeration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="boom-proc-fixture-")
        self.proc = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def stat(self, pid, ppid, starttime, state="S"):
        path = self.proc / str(pid) / "stat"
        path.parent.mkdir(exist_ok=True)
        # proc fields after comm: state is field 3, ppid field 4 and
        # starttime field 22 (index 19 in the split tail).
        middle = ["0"] * 17
        path.write_text(f"{pid} (fixture worker) {state} {ppid} " + " ".join(middle) + f" {starttime}\n")

    def test_missing_task_children_falls_back_to_ppid_scan(self):
        self.stat(201, 100, 7001)
        self.stat(202, 99, 7002)
        children, source, reliable = PROCESS.direct_children(100, self.proc)
        self.assertTrue(reliable)
        self.assertEqual(source, "proc-scan")
        self.assertEqual(children, [(201, "7001")])

    def test_task_children_omission_and_disappearing_entries_are_tolerated(self):
        children_file = self.proc / "self/task/100/children"
        children_file.parent.mkdir(parents=True)
        children_file.write_text("")
        (self.proc / "301").mkdir()
        self.stat(302, 100, 8002)
        children, source, reliable = PROCESS.direct_children(100, self.proc)
        self.assertTrue(reliable)
        self.assertEqual(source, "task-children+proc-scan")
        self.assertEqual(children, [(302, "8002")])

    def test_changed_starttime_or_parent_rejects_stale_pid(self):
        self.stat(401, 100, 9001)
        self.assertTrue(PROCESS.same_direct_child(401, "9001", 100, self.proc))
        self.stat(401, 100, 9002)
        self.assertFalse(PROCESS.same_direct_child(401, "9001", 100, self.proc))
        self.stat(401, 101, 9001)
        self.assertFalse(PROCESS.same_direct_child(401, "9001", 100, self.proc))


@unittest.skipUnless(LINUX, "Linux /proc required; Windows/MSYS is not a kernel test")
class Lifecycle(unittest.TestCase):
    def setUp(self):
        for tool in ("bash", "flock"):
            if not shutil.which(tool):
                self.skipTest(f"missing {tool}")
        self.temp = tempfile.TemporaryDirectory(prefix="boom-lifecycle-")
        self.base = Path(self.temp.name)
        self.lock = self.base / "adapter.lock"
        self.jobs = []
        self.handles = []
        self.env = dict(os.environ, BT_OPS_LOCK_FILE=str(self.lock))
        # Executable launcher also works on a checkout without executable bits.
        runner = self.base / "runner"
        runner.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{ROOT / "lib/bluetooth-process.py"}" "$@"\n')
        runner.chmod(0o700)
        self.env["BT_PROCESS_RUNNER"] = str(runner)

    @staticmethod
    def live(pid):
        try:
            # Ignore zombies: they hold neither FDs nor executing commands.
            return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
        except (FileNotFoundError, ProcessLookupError):
            return False

    @staticmethod
    def until(predicate, seconds=10):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if predicate():
                return True
            time.sleep(.05)
        return bool(predicate())

    def start(self, args):
        stream = (self.base / f"process-{len(self.jobs)}.log").open("wb")
        self.handles.append(stream)
        process = subprocess.Popen(args, env=self.env, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        self.jobs.append(process)
        return process

    def free(self):
        return subprocess.run(["flock", "-n", str(self.lock), "true"],
                              timeout=2, check=False).returncode == 0

    def tearDown(self):
        result = self._outcome.result
        if any(case is self for case, _ in result.errors + result.failures):
            for log in self.base.glob("*.log"):
                print(log.name + "\n" + log.read_text(errors="replace"), file=sys.stderr)
        # Only sessions created by THIS test. Never pkill/killall, never hci/DBus.
        for process in self.jobs:
            for item in Path("/proc").iterdir():
                if not item.name.isdigit():
                    continue
                pid = int(item.name)
                try:
                    if os.getsid(pid) == process.pid:
                        os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait(timeout=5)
        for stream in self.handles:
            stream.close()
        self.temp.cleanup()

    def holder(self, release=False):
        script = r'''
source "$1/lib/bluetooth-ops.sh"
bt_ops_acquire lifecycle 1 || exit 1
if [ "$3" = yes ]; then
  sleep 120 &
  printf '%s\n' "$!" > "$2/worker"
  bt_ops_release
else
  bt_process_run 120 bash -c 'echo $$ > "$1/worker"; exec sleep 120' worker "$2" &
fi
wait
'''
        return self.start(["bash", "-c", script, "holder", str(ROOT),
                           str(self.base), "yes" if release else "no"])

    def test_explicit_unlock_releases_inherited_description(self):
        self.holder(release=True)
        self.assertTrue(self.until(lambda: (self.base / "worker").exists()))
        self.assertTrue(self.until(self.free, 2))

    def test_orphan_must_not_pin_shared_lock(self):
        parent = self.holder()
        self.assertTrue(self.until(lambda: (self.base / "worker").exists()))
        self.assertFalse(self.free())
        worker = int((self.base / "worker").read_text())
        for fd in Path(f"/proc/{worker}/fd").iterdir():
            try:
                self.assertNotEqual(fd.resolve(), self.lock, "Bluetooth worker inherited lock")
            except FileNotFoundError:
                pass
        parent.kill()
        parent.wait(timeout=2)
        self.assertTrue(self.until(lambda: not self.live(worker), 3))
        self.assertTrue(self.until(self.free, 2), "orphan retains shared lock FD")

    def manager(self, stage, wait_worker=True, background=False):
        bindir = self.base / "bin"
        bindir.mkdir()
        for name in ("gatttool", "bluetoothctl", "pactl", "mosquitto_pub", "mosquitto_sub"):
            executable = bindir / name
            executable.write_text(f"#!{sys.executable}\n" + FAKE)
            executable.chmod(0o700)
        self.env.update(
            PATH=str(bindir) + os.pathsep + os.environ["PATH"],
            LIFECYCLE_TMP=str(self.base), LIFECYCLE_STAGE=stage,
            PM_BT_OPS_LIB=str(ROOT / "lib/bluetooth-ops.sh"),
            PM_GATT_DISCOVERY_LIB=str(ROOT / "lib/gatt-discovery.sh"),
            PM_MAC="C0:28:8D:82:F7:BB", PM_NAME="FAKE BOOM", PM_ENABLED="true",
            PM_BLE_WAKE="true", PM_ADAPTER_MAC="8C:68:AB:E0:3F:F6",
            PM_MQTT_HOST="FAKE-NO-NETWORK", PM_TEST_MAX_LOOPS="0",
            PM_PAUSE_DIR=str(self.base / "pause"), PM_RENDERER_DIR=str(self.base / "wake"))
        if background:
            parent = self.start(["bash", "-c", '"$1" exec bash "$2" & echo $! > "$3/manager-pid"; wait',
                                 "launcher", self.env["BT_PROCESS_RUNNER"],
                                 str(ROOT / "lib/power-manager.sh"), str(self.base)])
        else:
            parent = self.start(["bash", str(ROOT / "lib/power-manager.sh")])
        if not wait_worker:
            return parent, 0
        self.assertTrue(self.until(lambda: (self.base / "worker").exists()),
                        "fake worker not reached; inspect process log")
        return parent, int((self.base / "worker").read_text())

    def check_signal(self, stage, sig):
        parent, worker = self.manager(stage)
        # Signal ONLY the real power-manager PID, not its entire process group.
        parent.send_signal(sig)
        gone = self.until(lambda: not self.live(worker) and parent.poll() is not None, 10)
        self.assertTrue(gone, f"{stage}/{sig}: parent or owned worker survived 10s")
        self.assertTrue(self.until(self.free, 2), "lock still held after abort")

    def test_info_term(self): self.check_signal("info", signal.SIGTERM)
    def test_info_int(self): self.check_signal("info", signal.SIGINT)
    def test_info_kill(self): self.check_signal("info", signal.SIGKILL)
    def test_gatt_term(self): self.check_signal("gatt", signal.SIGTERM)
    def test_gatt_int(self): self.check_signal("gatt", signal.SIGINT)
    def test_gatt_kill(self): self.check_signal("gatt", signal.SIGKILL)

    def test_gatt_timeout_cleanup_and_error(self):
        parent, worker = self.manager("gatt")
        self.assertTrue(self.until(lambda: not self.live(worker), 10), "timeout leaked worker")
        self.assertTrue(self.until(self.free, 2), "timeout retained lock")
        marker = self.base / "wake/C0:28:8D:82:F7:BB.error"
        self.assertTrue(self.until(marker.exists, 2), "missing ERROR marker")
        self.assertIsNone(parent.poll(), "normal GATT failure killed MQTT loop")

    def test_repeated_signals(self):
        parent, worker = self.manager("info")
        parent.send_signal(signal.SIGTERM)
        parent.send_signal(signal.SIGINT)
        self.assertTrue(self.until(lambda: parent.poll() is not None and not self.live(worker)))
        self.assertTrue(self.until(self.free, 2))

    def test_unknown_connection_is_never_disconnected(self):
        parent, _ = self.manager("unknown-owner", wait_worker=False)
        marker = self.base / "wake/C0:28:8D:82:F7:BB.error"
        self.assertTrue(self.until(marker.exists, 15))
        calls = (self.base / "calls").read_text()
        self.assertNotIn("bluetoothctl disconnect", calls)
        self.assertNotIn("gatttool", calls)
        self.assertIsNone(parent.poll())

    def test_busy_cleanup_and_new_wake(self):
        parent, _ = self.manager("busy", wait_worker=False)
        marker = self.base / "wake/C0:28:8D:82:F7:BB.error"
        self.assertTrue(self.until(marker.exists, 15))
        self.assertTrue(self.until(self.free, 2))
        self.assertNotIn("bluetoothctl disconnect", (self.base / "calls").read_text())
        (self.base / "new-wake").touch()
        self.assertTrue(self.until(lambda: (self.base / "calls").read_text().count("gatttool ") >= 6, 15))
        self.assertIsNone(parent.poll())

    def test_info_deadline(self):
        # An isolated runner test: no MQTT state machine can mask the timeout.
        self.env.update(LIFECYCLE_TMP=str(self.base), LIFECYCLE_STAGE="info")
        fake = self.base / "bluetoothctl"
        fake.write_text(f"#!{sys.executable}\n" + FAKE)
        fake.chmod(0o700)
        process = self.start([self.env["BT_PROCESS_RUNNER"], str(os.getpid()), "0.3", "", str(fake), "info"])
        self.assertEqual(process.wait(timeout=5), 124)
        worker = int((self.base / "worker").read_text())
        self.assertFalse(self.live(worker))

    def test_short_lived_processes_keep_success_status(self):
        scan_env = dict(self.env, BT_PROCESS_FORCE_PROC_SCAN="1")
        for _attempt in range(20):
            process = subprocess.run(
                [self.env["BT_PROCESS_RUNNER"], str(os.getpid()), "2", "", "true"],
                env=scan_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, timeout=5, check=False)
            self.assertEqual(process.returncode, 0, process.stdout)

    def test_adopted_descendant_reaped(self):
        parent, worker = self.manager("tree")
        self.assertTrue(self.until(lambda: (self.base / "grandchild").exists()))
        grandchild = int((self.base / "grandchild").read_text())
        self.assertTrue(self.until(lambda: not self.live(worker) and not self.live(grandchild)))
        self.assertTrue(self.until(self.free, 2))
        self.assertIsNone(parent.poll())

    def test_adopted_descendant_reaped_with_proc_scan_fallback(self):
        self.env["BT_PROCESS_FORCE_PROC_SCAN"] = "1"
        parent, worker = self.manager("tree")
        self.assertTrue(self.until(lambda: (self.base / "grandchild").exists()))
        grandchild = int((self.base / "grandchild").read_text())
        self.assertTrue(self.until(lambda: not self.live(worker) and not self.live(grandchild)))
        self.assertTrue(self.until(self.free, 2))
        self.assertIsNone(parent.poll())

    def test_background_manager_receives_int(self):
        launcher, worker = self.manager("info", background=True)
        manager = int((self.base / "manager-pid").read_text())
        os.kill(manager, signal.SIGINT)
        self.assertTrue(self.until(lambda: launcher.poll() is not None and not self.live(worker)))
        self.assertTrue(self.until(self.free, 2))


if __name__ == "__main__":
    unittest.main()
