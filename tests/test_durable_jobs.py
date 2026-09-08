"""Offline custody/recovery tests through the shipped CLI and real processes."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "bin" / "thinkers"
JOBS = REPO / "tools" / "headlong-jobs"

HANDLER = '''#!/usr/bin/env python3
import hashlib,json,os,signal,subprocess,sys,time
from pathlib import Path
envelope=json.load(sys.stdin)
directory=Path(os.environ['HEADLONG_JOB_DIR'])
directory.joinpath('received.json').write_text(json.dumps(envelope))
mode=envelope['admitted'].get('mode','complete')
if mode=='hold':
    child=subprocess.Popen([sys.executable,'-c',"import time; time.sleep(120)"])
    directory.joinpath('child.pid').write_text(str(child.pid))
    while not directory.joinpath('release').exists(): time.sleep(.03)
if mode=='attempts':
    command=[os.environ['JOB_TEST_TOOL'],'attempt',envelope['job_id']]
    stub=envelope['admitted']['stub']
    for phase in ['fast/1','fast/1','settle/1']:
        result=subprocess.run(command+[phase,'--',stub],input=b'hello',capture_output=True)
        if result.returncode: raise RuntimeError(result.stderr.decode())
    wrong=subprocess.run([os.environ['JOB_TEST_TOOL'],'attempt','wrong-job','fast/1','--',stub],input=b'hello',capture_output=True)
    if wrong.returncode==0: raise RuntimeError('wrong job permitted')
if mode=='uncertain':
    command=[os.environ['JOB_TEST_TOOL'],'attempt',envelope['job_id'],'fast/1','--',envelope['admitted']['stub']]
    first=subprocess.run(command,input=b'hello',capture_output=True)
    second=subprocess.run(command,input=b'hello',capture_output=True)
    if first.returncode!=75 or second.returncode!=75: raise RuntimeError('uncertain CREATE retried')
    directory.joinpath('attempt-deduped').touch()
    while not directory.joinpath('release').exists(): time.sleep(.03)
if mode=='slowattempt':
    subprocess.run([os.environ['JOB_TEST_TOOL'],'attempt',envelope['job_id'],'fast/1','--',envelope['admitted']['stub']],input=b'hello')
if mode=='adapter':
    env=dict(os.environ,LLM_ADAPTER=envelope['admitted']['stub'],LLM_MAX_TIME=envelope['admitted'].get('deadline','600'),LLM_API_FORMAT='responses')
    subprocess.run([os.environ['JOB_TEST_TOOL'],'attempt',envelope['job_id'],'fast/1','--',envelope['admitted']['llm'],'--provider','adapter','--model','fixture-model'],input=b'hello',env=env)
if mode=='parallel-adapters':
    commands=[]
    for phase,deadline in [('fast/1','1'),('settle/1','10')]:
        env=dict(os.environ,LLM_ADAPTER=envelope['admitted']['stub'],LLM_MAX_TIME=deadline,LLM_API_FORMAT='responses')
        command=[os.environ['JOB_TEST_TOOL'],'attempt',envelope['job_id'],phase,'--',envelope['admitted']['llm'],'--provider','adapter','--model','fixture-model']
        command_process=subprocess.Popen(command,stdin=subprocess.PIPE,env=env)
        command_process.stdin.write(b'hello'); command_process.stdin.close()
        commands.append(command_process)
    directory.joinpath('phases-running').touch()
    outcomes=[process.wait() for process in commands]
    directory.joinpath('phase-exits.json').write_text(json.dumps(outcomes))
if mode=='await-child':
    directory.joinpath('parent-ready').touch()
    if envelope['admitted'].get('barrier'):
        while not Path(os.environ['IDENTITY_DIR']).joinpath('begin-waits').exists(): time.sleep(.03)
    depth=envelope['admitted']['depth']
    child=dict(envelope,job_id=envelope['job_id']+'/child',parent_job_id=envelope['job_id'])
    child['admitted']={'mode':'await-child' if depth>1 else ('hold' if envelope['admitted'].get('leaf_hold') else 'complete'),'depth':depth-1}
    admitted=subprocess.run([os.environ['JOB_TEST_TOOL'],'admit'],input=json.dumps(child).encode(),capture_output=True)
    if admitted.returncode: raise RuntimeError(admitted.stderr.decode())
    receipt=subprocess.run([os.environ['JOB_TEST_TOOL'],'wait-child',envelope['job_id'],child['job_id']],capture_output=True)
    if receipt.returncode: raise RuntimeError(receipt.stderr.decode())
    directory.joinpath('child-receipt.json').write_bytes(receipt.stdout)
if mode=='cooperative':
    def cancel(*_):
        Path(os.environ['HEADLONG_JOB_RESULT_FILE']).write_text(json.dumps({'outcome':'cancelled','evidence':'cooperative local stop'}))
        sys.exit(0)
    signal.signal(signal.SIGTERM,cancel)
    directory.joinpath('ready').touch()
    while True: time.sleep(.03)
Path(os.environ['HEADLONG_JOB_RESULT_FILE']).write_text(json.dumps({'outcome':'completed','result':{'subject':envelope['trigger_step']}}))
if mode=='failed-after-result': sys.exit(1)
'''


def wait_for(predicate, timeout=15):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = predicate()
        if value:
            return value
        time.sleep(.04)
    raise AssertionError("timed out waiting for observed state")


def is_running(pid):
    result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
    return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.lstrip().startswith("Z")


class DurableJobs(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="headlong-jobs-")
        self.identity = Path(self.temp.name) / "identity"
        self.identity.mkdir()
        self.env = dict(os.environ, IDENTITY_DIR=str(self.identity), JOB_TEST_TOOL=str(JOBS),
                        PATH=str(REPO / "bin") + os.pathsep + os.environ["PATH"], HEADLONG_JOBS_MAX_CONCURRENT="4",
                        HEADLONG_JOB_CANCEL_GRACE="0.2", HEADLONG_HOME=str(self.identity / "framework-home"),
                        LLM_USAGE_LEDGER=str(self.identity / "usage.jsonl"))
        self.handler = Path(self.temp.name) / "handler"
        self.handler.write_text(HANDLER)
        self.handler.chmod(0o700)
        self.hash = self.call("register", "application", data={"version": "fixture-1", "argv": [str(self.handler)]})["handler_hash"]
        self.dispatchers = []

    def tearDown(self):
        try:
            for row in self.call("list"):
                self.call("cancel", row["job_id"])
            self.call("stop")
            wait_for(lambda: all(not is_running(pid) for pid in self.dispatchers), timeout=5)
            # Cancels can finish after the dispatcher stops; custody workers
            # poll the durable fence independently of the dispatcher.
            db = sqlite3.connect(self.identity / "jobs" / "ledger.sqlite3")
            workers = [row[0] for row in db.execute("SELECT worker_pid FROM jobs WHERE worker_pid IS NOT NULL")]
            db.close()
            wait_for(lambda: all(not is_running(pid) for pid in workers), timeout=5)
        finally:
            self.temp.cleanup()

    def call(self, *args, data=None, success=True):
        result = subprocess.run([str(CLI), "jobs", *args], input=json.dumps(data) if data is not None else "",
                                env=self.env, text=True, capture_output=True, timeout=15)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def envelope(self, name, **context):
        return {"version": 1, "job_id": name, "trigger_step": "subject-" + name,
                "kind": "application", "handler": "application", "handler_hash": self.hash,
                "admitted": context}

    def directory(self, name):
        return self.identity / "jobs" / "work" / hashlib.sha256(name.encode()).hexdigest()

    def start(self):
        result = subprocess.run([str(CLI), "start", "--jobs-only"], env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        pid = json.loads(result.stdout)["dispatcher_pid"]
        self.dispatchers.append(pid)
        return pid

    def state(self, name, state):
        return wait_for(lambda: (row if (row := self.call("get", name))["state"] == state else None))

    def dbrow(self, name):
        db = sqlite3.connect(self.identity / "jobs" / "ledger.sqlite3")
        db.row_factory = sqlite3.Row
        row = dict(db.execute("SELECT * FROM jobs WHERE job_id=?", (name,)).fetchone())
        db.close()
        return row

    def test_durable_admission_dedupe_context_and_no_queue_drop(self):
        context = {"actor": {"id": "same-label-agent", "kind": "agent"}, "delegation": ["grant-1", "grant-2"],
            "roster": [{"id": "h1", "label": "Sam"}, {"id": "h2", "label": "Sam"}, {"id": "a1", "label": "Sam"}],
            "runtime": {"resident": "persistent", "capabilities": ["typed-effects"]}}
        envelope = self.envelope("one", **context)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            receipts = list(pool.map(lambda _: self.call("admit", data=envelope), range(8)))
        self.assertTrue(all(r["envelope_hash"] == receipts[0]["envelope_hash"] for r in receipts))
        self.call("admit", data=self.envelope("one", changed=True), success=False)
        for i in range(24):
            self.call("admit", data=self.envelope("queued-" + str(i)))
        self.assertEqual(len(self.call("list")), 25)
        self.start()
        wait_for(lambda: all(row["state"] == "completed" for row in self.call("list")))
        self.assertEqual(json.loads((self.directory("one") / "received.json").read_text()), envelope)
        events = [json.loads(line) for line in (self.identity / "jobs" / "trajectory.jsonl").read_text().splitlines()]
        self.assertEqual(sum(event["type"] == "job-running" and event["job_id"] == "one" for event in events), 1)
        denied = subprocess.run([str(CLI), "start"], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("durable jobs", denied.stderr)

    def test_dispatcher_crash_run_deletion_restart_and_exact_child_cancel(self):
        for name in ("a", "b"):
            self.call("admit", data=self.envelope(name, mode="hold"))
        pid = self.start()
        for name in ("a", "b"):
            wait_for(lambda name=name: (self.directory(name) / "child.pid").exists())
        a_child = int((self.directory("a") / "child.pid").read_text())
        b_child = int((self.directory("b") / "child.pid").read_text())
        before = self.call("get", "a")["execution_id"]
        os.kill(pid, signal.SIGKILL)
        wait_for(lambda: not is_running(pid))
        shutil.rmtree(self.identity / "run")
        self.call("admit", data=self.envelope("after-crash"))
        self.start()
        self.state("after-crash", "completed")
        self.assertEqual(self.call("get", "a")["execution_id"], before)
        self.call("cancel", "a")
        self.state("a", "unknown")
        wait_for(lambda: not is_running(a_child))
        self.assertTrue(is_running(b_child), "cancellation reached another job's process group")
        (self.directory("b") / "release").touch()
        self.state("b", "completed")
        wait_for(lambda: not is_running(b_child))

    def test_worker_crash_reconciles_unknown_and_sweeps_descendants(self):
        self.call("admit", data=self.envelope("crash", mode="hold"))
        self.start()
        wait_for(lambda: (self.directory("crash") / "child.pid").exists())
        child = int((self.directory("crash") / "child.pid").read_text())
        row = self.dbrow("crash")
        os.kill(row["worker_pid"], signal.SIGKILL)
        self.state("crash", "unknown")
        wait_for(lambda: not is_running(child))
        replay = self.call("admit", data=self.envelope("crash", mode="hold"))
        self.assertEqual(replay["state"], "unknown")
        self.assertEqual(replay["execution_id"], row["execution"])
        self.call("recover", "crash", data={"outcome": "completed", "execution_id": "wrong",
            "receipt_ref": "verified-worker-report", "receipt_sha256": "a" * 64}, success=False)
        recovered = self.call("recover", "crash", data={"outcome": "completed", "execution_id": row["execution"],
            "receipt_ref": "verified-worker-report", "receipt_sha256": "a" * 64})
        self.assertEqual(recovered["state"], "completed")

    def test_phase_attempt_dedupe_uses_typed_sidecar_and_rejects_external_call(self):
        stub = Path(self.temp.name) / "completion"
        stub.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
sys.stdin.read()
with (Path(os.environ['IDENTITY_DIR'])/'calls').open('a') as out: out.write(os.environ['HEADLONG_JOB_ATTEMPT_ID']+'\\n')
Path(os.environ['LLM_RESPONSE_FILE']).write_text(json.dumps({'id':'response_fixture','status':'completed','output':[]}))
print('answer')
''')
        stub.chmod(0o700)
        self.call("admit", data=self.envelope("phases", mode="attempts", stub=str(stub)))
        self.call("attempt", "phases", "external", "--", str(stub), success=False)
        self.start()
        self.state("phases", "completed")
        self.assertEqual((self.identity / "calls").read_text().splitlines(), ["fast/1", "settle/1"])

    def test_unknown_attempt_never_recreates(self):
        stub = Path(self.temp.name) / "uncertain"
        stub.write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
sys.stdin.read()
with (Path(os.environ['IDENTITY_DIR'])/'calls').open('a') as out: out.write('create\\n')
sys.exit(75)
''')
        stub.chmod(0o700)
        self.call("admit", data=self.envelope("unknown", mode="uncertain", stub=str(stub)))
        self.start()
        wait_for(lambda: (self.directory("unknown") / "attempt-deduped").exists())
        self.assertEqual((self.identity / "calls").read_text().splitlines(), ["create"])
        self.call("cancel", "unknown")
        self.state("unknown", "unknown")

    def test_attempt_sidecar_survives_supervisor_death_without_replay(self):
        stub = Path(self.temp.name) / "sidecar-before-crash"
        stub.write_text('''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
sys.stdin.read()
with (Path(os.environ['IDENTITY_DIR'])/'calls').open('a') as out: out.write('create\\n')
Path(os.environ['LLM_RESPONSE_FILE']).write_text(json.dumps({'id':'response_recoverable','status':'completed','output':[]}))
Path(os.environ['HEADLONG_JOB_DIR']).joinpath('provider-completed').touch()
time.sleep(120)
''')
        stub.chmod(0o700)
        self.call("admit", data=self.envelope("sidecar", mode="slowattempt", stub=str(stub)))
        self.start()
        wait_for(lambda: (self.directory("sidecar") / "provider-completed").exists())
        os.kill(self.dbrow("sidecar")["worker_pid"], signal.SIGKILL)
        self.state("sidecar", "unknown")
        attempts = self.call("attempts", "sidecar")
        self.assertEqual(attempts[0]["state"], "completed")
        self.assertFalse(attempts[0]["result"]["replayable"])
        self.assertEqual(attempts[0]["result"]["response"]["id"], "response_recoverable")
        self.assertEqual((self.identity / "calls").read_text().splitlines(), ["create"])

    def test_starting_crash_snapshot_never_runs_and_queued_work_survives_stop(self):
        self.env["HEADLONG_JOBS_MAX_CONCURRENT"] = "0"
        self.call("admit", data=self.envelope("fenced"))
        self.call("admit", data=self.envelope("queued"))
        pid = self.start()
        self.call("stop")
        wait_for(lambda: not is_running(pid))
        self.assertEqual(self.call("get", "queued")["state"], "queued")
        # The durable snapshot after a crash between the start transaction
        # and Popen. Nothing can establish whether an external worker began.
        db = sqlite3.connect(self.identity / "jobs" / "ledger.sqlite3")
        db.execute("UPDATE jobs SET state='starting',execution='crashed-before-spawn' WHERE job_id='fenced'")
        db.commit()
        db.close()
        self.env["HEADLONG_JOBS_MAX_CONCURRENT"] = "4"
        self.start()
        self.state("fenced", "unknown")
        self.state("queued", "completed")
        self.assertFalse((self.directory("fenced") / "received.json").exists())

    def test_legacy_dispatch_works_but_custody_loss_refuses_jobs_migration(self):
        thinker = self.identity / "thinkers" / "fixture"
        thinker.mkdir(parents=True)
        (thinker / "step").write_text('#!/usr/bin/env bash\ncat > "$IDENTITY_DIR/legacy-received"\necho $$ > "$IDENTITY_DIR/legacy-child"\nexec sleep 120\n')
        (thinker / "step").chmod(0o700)
        (thinker / "subscriptions.jsonl").write_text('{"types":["action"]}\n')
        trajectory = self.identity / "trajectories" / "fixture"
        trajectory.mkdir(parents=True)
        (trajectory / "trajectory.jsonl").touch()
        env = dict(self.env, IDENTITY_NAME="fixture", TRAJ_DIR=str(trajectory.parent), TRAJ_ID="fixture")
        result = subprocess.run([str(CLI), "start"], env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        pid = int((self.identity / "run" / "dispatcher.pid").read_text())
        self.dispatchers.append(pid)
        try:
            wait_for(lambda: (self.identity / "run" / "tail_pids").exists())
            time.sleep(.1)
            with (trajectory / "trajectory.jsonl").open("a") as out:
                out.write('{"type":"action","content":"legacy"}\n')
            wait_for(lambda: (self.identity / "legacy-received").exists())
            wait_for(lambda: (self.identity / "legacy-child").exists())
            legacy_child = int((self.identity / "legacy-child").read_text())
            shutil.rmtree(self.identity / "run")
            denied = subprocess.run([str(CLI), "start", "--jobs-only"], env=self.env, capture_output=True, text=True, timeout=15)
            self.assertNotEqual(denied.returncode, 0)
            self.assertIn("legacy execution has not been reconciled", denied.stderr)
            self.assertTrue(is_running(legacy_child))
            os.kill(legacy_child, signal.SIGTERM)
            wait_for(lambda: not is_running(legacy_child) and not is_running(pid))
            epoch = self.call("legacy-status")["legacy_execution"]
            evidence = {"quiescent": True, "receipt_ref": "local-process-inventory", "receipt_sha256": "b" * 64}
            self.call("retire-legacy", data=dict(evidence, legacy_execution="stale-epoch"), success=False)
            self.call("retire-legacy", data=dict(evidence, legacy_execution=epoch))
            self.start()
        finally:
            stop_args = ["stop"] if (self.identity / "jobs" / "mode.json").exists() else ["stop", "--force"]
            stopped = subprocess.run([str(CLI), *stop_args], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(stopped.returncode, 0, stopped.stderr)

    def test_real_llm_adapter_subgroup_is_owned_on_cancel_deadline_and_crash(self):
        stub = Path(self.temp.name) / "adapter"
        stub.write_text('''#!/usr/bin/env python3
import json,os,signal,sys,time
from pathlib import Path
sys.stdin.read()
signal.signal(signal.SIGTERM,signal.SIG_IGN)
Path(os.environ['HEADLONG_JOB_DIR']).joinpath('adapter.json').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp()}))
while True: time.sleep(.05)
''')
        stub.chmod(0o700)
        self.call("admit", data=self.envelope("adapter-cancel", mode="adapter", stub=str(stub), llm=str(REPO / "bin" / "llm")))
        self.start()
        wait_for(lambda: (self.directory("adapter-cancel") / "adapter.json").exists())
        adapter = json.loads((self.directory("adapter-cancel") / "adapter.json").read_text())
        db = sqlite3.connect(self.identity / "jobs" / "ledger.sqlite3")
        owned_group = db.execute("SELECT adapter_pgid FROM attempts WHERE job_id='adapter-cancel'").fetchone()[0]
        db.close()
        self.assertEqual(adapter["pgid"], owned_group)
        self.call("cancel", "adapter-cancel")
        self.state("adapter-cancel", "unknown")
        wait_for(lambda: not is_running(adapter["pid"]))
        self.call("admit", data=self.envelope("adapter-deadline", mode="adapter", stub=str(stub), llm=str(REPO / "bin" / "llm"), deadline="1"))
        wait_for(lambda: (self.directory("adapter-deadline") / "adapter.json").exists())
        adapter = json.loads((self.directory("adapter-deadline") / "adapter.json").read_text())
        row = self.state("adapter-deadline", "unknown")
        self.assertFalse(row["cancel_requested"], "attempt deadline cancelled the whole job")
        wait_for(lambda: not is_running(adapter["pid"]))
        self.call("admit", data=self.envelope("adapter-crash", mode="adapter", stub=str(stub), llm=str(REPO / "bin" / "llm")))
        wait_for(lambda: (self.directory("adapter-crash") / "adapter.json").exists())
        adapter = json.loads((self.directory("adapter-crash") / "adapter.json").read_text())
        os.kill(self.dbrow("adapter-crash")["worker_pid"], signal.SIGKILL)
        self.state("adapter-crash", "unknown")
        wait_for(lambda: not is_running(adapter["pid"]))

    def test_fast_deadline_preserves_settle_attempt_and_child_commission(self):
        stub = Path(self.temp.name) / "phase-adapter"
        stub.write_text('''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
sys.stdin.read()
if os.environ['HEADLONG_JOB_ATTEMPT_ID']=='fast/1': time.sleep(120)
else:
    time.sleep(2)
    Path(os.environ['LLM_RESPONSE_FILE']).write_text(json.dumps({'id':'response_settle','status':'completed','output':[]}))
    print('settle completed')
''')
        stub.chmod(0o700)
        self.call("admit", data=self.envelope("parallel", mode="parallel-adapters", stub=str(stub), llm=str(REPO / "bin" / "llm")))
        self.start()
        wait_for(lambda: (self.directory("parallel") / "phases-running").exists())
        child = self.envelope("commission", mode="hold")
        child["parent_job_id"] = "parallel"
        self.call("admit", data=child)
        wait_for(lambda: (self.directory("commission") / "child.pid").exists())
        row = self.state("parallel", "unknown")
        self.assertFalse(row["cancel_requested"])
        self.assertEqual(json.loads((self.directory("parallel") / "phase-exits.json").read_text()), [75, 0])
        attempts = {row["attempt_id"]: row for row in self.call("attempts", "parallel")}
        self.assertEqual(attempts["fast/1"]["state"], "unknown")
        self.assertEqual(attempts["settle/1"]["state"], "completed")
        commission = self.call("get", "commission")
        self.assertEqual(commission["state"], "running")
        self.assertFalse(commission["cancel_requested"])
        (self.directory("commission") / "release").touch()
        self.state("commission", "completed")

    def test_four_waiting_parents_release_slots_through_two_child_levels(self):
        for index in range(4):
            self.call("admit", data=self.envelope("parent-" + str(index), mode="await-child", depth=2, barrier=True))
        self.start()
        for index in range(4):
            wait_for(lambda index=index: (self.directory("parent-" + str(index)) / "parent-ready").exists())
        before = {row["job_id"]: row["execution_id"] for row in self.call("list")}
        (self.identity / "begin-waits").touch()
        observed = []
        def all_complete():
            rows = self.call("list")
            observed.append(sum(row["state"] in {"starting", "running"} for row in rows))
            return rows if len(rows) == 12 and all(row["state"] == "completed" for row in rows) else None
        rows = wait_for(all_complete, timeout=20)
        self.assertLessEqual(max(observed), 4)
        for row in rows:
            if row["job_id"] in before:
                self.assertEqual(row["execution_id"], before[row["job_id"]])
                self.assertEqual(json.loads((self.directory(row["job_id"]) / "child-receipt.json").read_text())["state"], "completed")

    def test_cancellation_wakes_waiting_parent_and_stops_its_child(self):
        self.call("admit", data=self.envelope("waiting", mode="await-child", depth=1, leaf_hold=True))
        self.call("wait-child", "waiting", "wrong-child", success=False)
        self.start()
        self.state("waiting", "waiting")
        wait_for(lambda: (self.directory("waiting/child") / "child.pid").exists())
        child_pid = int((self.directory("waiting/child") / "child.pid").read_text())
        self.call("cancel", "waiting")
        self.state("waiting", "unknown")
        self.state("waiting/child", "unknown")
        wait_for(lambda: not is_running(child_pid))

    def test_waiting_parent_restart_preserves_execution_and_crash_stays_unknown(self):
        envelope = self.envelope("waiting-restart", mode="await-child", depth=1, leaf_hold=True)
        self.call("admit", data=envelope)
        dispatcher = self.start()
        row = self.state("waiting-restart", "waiting")
        wait_for(lambda: (self.directory("waiting-restart/child") / "child.pid").exists())
        execution = row["execution_id"]
        os.kill(dispatcher, signal.SIGKILL)
        wait_for(lambda: not is_running(dispatcher))
        shutil.rmtree(self.identity / "run")
        self.start()
        self.assertEqual(self.state("waiting-restart", "waiting")["execution_id"], execution)
        os.kill(self.dbrow("waiting-restart")["worker_pid"], signal.SIGKILL)
        self.state("waiting-restart", "unknown")
        repeated = self.call("admit", data=envelope)
        self.assertEqual(repeated["state"], "unknown")
        self.assertEqual(repeated["execution_id"], execution)
        self.assertEqual(len(self.call("list")), 2)
        self.call("cancel", "waiting-restart")
        self.state("waiting-restart/child", "unknown")

    def test_completed_handler_receipt_cannot_hide_nonzero_exit(self):
        self.call("admit", data=self.envelope("failed", mode="failed-after-result"))
        self.start()
        row = self.state("failed", "unknown")
        self.assertEqual(row["result"]["reason"], "handler_did_not_exit_successfully")

    def test_preupgrade_identity_requires_explicit_quiescence(self):
        (self.identity / "info.txt").write_text("name=historical\n")
        denied = subprocess.run([str(CLI), "start", "--jobs-only"], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("legacy execution has not been reconciled", denied.stderr)
        self.assertTrue(self.call("legacy-status")["legacy_execution"].startswith("untracked-"))

    def test_parent_cancel_fence_and_cooperative_terminal(self):
        self.call("admit", data=self.envelope("parent", mode="cooperative"))
        child = self.envelope("child", mode="cooperative")
        child["parent_job_id"] = "parent"
        self.call("admit", data=child)
        self.start()
        for name in ("parent", "child"):
            wait_for(lambda name=name: (self.directory(name) / "ready").exists())
        self.call("cancel", "parent")
        self.state("parent", "cancelled")
        self.state("child", "cancelled")
        late = self.envelope("late")
        late["parent_job_id"] = "parent"
        self.call("admit", data=late, success=False)

    def test_queued_cancel_and_changed_registered_bytes_fail_closed(self):
        self.call("admit", data=self.envelope("queued"))
        self.assertEqual(self.call("cancel", "queued")["state"], "cancelled")
        self.call("admit", data=self.envelope("modified"))
        self.handler.write_text(HANDLER + "\n# changed after admission\n")
        self.start()
        row = self.state("modified", "unknown")
        self.assertEqual(row["result"]["reason"], "registered_handler_bytes_changed")
        self.assertFalse((self.directory("queued") / "received.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
