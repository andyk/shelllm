# Durable identity jobs

`thinkers start --jobs-only` selects the persistent identity's exclusive
application-job dispatcher. This mode owns application model turns and child
execution. It does not start responder, monolith, subscriptions, or trajectory
tailers. An application action enters exactly one admitted job. A model CLI
belongs inside that job's registered handler, never in a competing application
scheduler.

This is a local POSIX implementation using Python 3.8+ and SQLite. Keep the
identity on persistent local storage. SQLite WAL with `synchronous=FULL`,
transactions, and directory fsync establish admission custody; `run/` contains
only a disposable PID hint. Network filesystems and multi-host dispatchers are
not supported. Model/provider credentials and policy remain operator choices.

## Register and admit

Run registration from trusted deployment code, not from a client-authored
envelope. The executable must be absolute. The registry pins argv, declared
version, and the executable's SHA-256. The declared version must identify its
whole deployment, including any imported modules or interpreter arguments.
Admission snapshots the registration, so registering a later version cannot
silently redirect existing jobs. If the admitted executable's bytes change,
execution stops with `unknown`; deploy immutable executable paths.

```sh
export IDENTITY_DIR=/persistent/identities/example
thinkers jobs register application-turn < handler.json
# handler.json: {"version":"deployment-sha","argv":["/immutable/application-handler"]}
# => {"handler":"application-turn","handler_hash":"..."}
thinkers jobs admit < admission.json
thinkers start --jobs-only
```

The admission schema is:

```json
{
  "version": 1,
  "job_id": "canonical-job-id",
  "trigger_step": "canonical-subject-id",
  "parent_job_id": null,
  "kind": "application-action",
  "handler": "application-turn",
  "handler_hash": "hash-returned-by-registration",
  "admitted": {
    "subject_ref": "opaque-subject",
    "actor_ref": "opaque-verified-principal",
    "delegation_refs": ["opaque-grant"],
    "context_ref": "opaque-authorized-snapshot"
  }
}
```

`parent_job_id` is optional. `admitted` is an opaque object: Headlong preserves
every value, array, actor/delegation/roster/runtime field, and reference into
the actual handler's stdin. It applies no human-only reply filter. Use
references and revocable application capabilities; do not persist bearer
credentials in an envelope. Headlong does not authenticate these references or
turn historical provenance into rights.

Admission returns only after durable commit. The receipt includes `custody:
"durable"`, job ID, immutable envelope/handler hashes, state, execution ID and
result. Repeating the same job ID and JSON values returns existing custody;
different values under that ID fail. Queue capacity limits concurrent execution,
not admission retention: no capped pending queue, drop-oldest policy, or
start/stop clearing applies. `HEADLONG_JOBS_MAX_CONCURRENT` defaults to 4.

An application should commit its authorized canonical event before admission,
then mark its outbox delivered only from this receipt. Recovery may resubmit
the same envelope safely. The application still owns current resource rights,
tool/effect/cancellation fences, and final publication/promotion.

## Handler contract

The registered argv executes without shell interpretation. Stdin receives the
complete admission JSON. These environment variables identify its custody:

- `HEADLONG_JOB_ID` and `HEADLONG_JOB_EXECUTION_ID`.
- `HEADLONG_JOB_DIR`: persistent private evidence directory.
- `HEADLONG_JOB_RESULT_FILE`: write a JSON terminal receipt here.
- `HEADLONG_JOB_EXECUTION_TOKEN`: private process-custody token; never log it.

Write `{ "outcome": "completed"|"cancelled"|"unknown", "result": ... }` to the
result file and exit. Stdout/stderr are evidence files, not canonical replies.
The supervisor fsyncs and records the terminal receipt after stopping the whole
owned process group. A missing, malformed, or unconfirmed result stays unknown.
A handler's completed result cannot hide an unsettled model attempt. A late
completion after the durable cancellation fence is retained as unknown evidence.

A child commission is another admission with the exact parent job ID. The
registered handler executes the worker/task command and returns its candidate
and evidence. It cannot grant Room/customer membership, commit application
effects, approve its own output, or promote its candidate. Those remain the
application's authenticated effect boundary.

## Model attempts

Inside the admitted handler, run the typed Responses primitive through:

```sh
thinkers jobs attempt "$HEADLONG_JOB_ID" "settle/turn-2/tool-continuation-1" -- llm ... < input.json
```

Attempts retain the same job process group. This command refuses callers
outside that exact live job, wrong job IDs, and cancellation-fenced jobs. A
transaction commits the stable attempt ID before spawning. Its fingerprint
binds argv, stdin, LLM/SHELLM environment controls, optional
`HEADLONG_JOB_ATTEMPT_CONTEXT`, and the Responses body-file bytes. Only the
fingerprint is logged, not credentials. Use that optional context for immutable
phase/model-policy receipts. The wrapper snapshots the Responses body file so
the primitive consumes the exact bytes fingerprinted. Other files referenced by
the executable/argv remain deployment-owned immutable inputs.

The wrapper sets `HEADLONG_JOB_ATTEMPT_ID` and a persistent
`LLM_RESPONSE_FILE`. PR1's typed response sidecar establishes completed or
cancelled provider outcomes; stdout or a zero exit alone does not. Duplicate
successful attempts replay their durable stdout. Duplicate started or unknown
attempts return exit 75 and never CREATE again. Distinct stable phase and tool
continuation IDs permit legitimate multiple completions inside one job.

`thinkers jobs attempts JOB_ID` exposes typed attempt evidence for reconciliation.
After custody loss, a valid terminal sidecar can settle an attempt, but partial
stdout is never advertised as a replayable completed response. This operation
does not poll a provider, issue a new CREATE, or infer job completion from a
single model phase.

## Cancellation, restart, and recovery

`thinkers jobs cancel JOB_ID` atomically fences that job and its current child
tree. Subsequent child admissions are refused. A queued job becomes cancelled;
a running supervisor requests TERM, then stops the entire owned group. The
group leader remains unreaped until after killpg, reserving its PID/PGID so
cancellation cannot target a recycled unrelated process. A control-pipe EOF
stops descendants if the supervisor crashes. Process-group escape (`setsid`,
daemonization into another session) is outside this handler contract; run such
workers in a separately enforced process/container boundary before adopting
them. Remote cancellation remains unconfirmed until a typed terminal receipt.

`thinkers stop` (or `thinkers jobs stop`) pauses the jobs dispatcher, preserves
queued admissions, and lets supervised running jobs finish. It is not job
cancellation. `thinkers start --jobs-only` restarts dispatch; a concurrent start
fails closed. Legacy `thinkers start` is refused once an identity has selected
jobs-only mode, including after deletion of `run/`.

Startup reconciles existing custody before scheduling queued work. Live
supervisor locks remain authoritative after dispatcher death. A started job
whose supervisor and terminal execution receipt are both gone becomes unknown,
never requeued. SQLite's private events are projected to
`IDENTITY_DIR/jobs/trajectory.jsonl` with stable event IDs; that identity
trajectory survives runtime cleanup and is regenerable from the ledger.

Inspect with `thinkers jobs get JOB_ID` and `thinkers jobs list`. After actual
provider/worker evidence has been reconciled, trusted operator code may settle
an unknown job explicitly:

```sh
thinkers jobs recover JOB_ID < verified-recovery.json
```

The evidence object requires the exact `execution_id`, `outcome` of completed
or cancelled, a `receipt_ref`, and its lowercase 64-character `receipt_sha256`.
This is an operator attestation, not automatic verification of that referenced
receipt. It never reruns a handler, repeats a CREATE, clears cancellation,
expands admitted authority, or authorizes application promotion. Unknown jobs
with live supervisors cannot be settled this way. Additional authorized work
uses a new job with explicit causation after external outcome reconciliation.

The offline test is `tests/test_durable_jobs.sh`. It exercises concurrent
admission/dedupe, more than 16 queued jobs, actual handler context, dispatcher
and supervisor crashes, runtime-directory deletion, descendant cancellation,
independent concurrent jobs, child fences, typed attempt dedupe, and explicit
unknown reconciliation. It uses real local processes and synthetic typed
Responses receipts; it does not claim live provider or application effect-door
verification.
