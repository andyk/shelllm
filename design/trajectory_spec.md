# Trajectory Spec

Status: COMPLETE — bin/traj and bin/chat implement the documented format and subcommands.

A **trajectory** is an append-only log of steps stored as a JSONL file named `trajectory.jsonl` inside a directory. Each line is a JSON object representing one step. Trajectories record what an agent did, thought, observed, and produced during a run.

## Core concepts

A trajectory is itself a step. The first line of every `trajectory.jsonl` file is a step with `"type":"trajectory"` whose `step_id` serves as the trajectory's ID. This means trajectories and steps share a single ID namespace — any UUID in the system can be looked up uniformly with `traj show <id>`.

Steps are append-only. Once written, a step is never modified.

## Directory structure

Each trajectory is a directory containing `trajectory.jsonl`. Child trajectories are nested as subdirectories of their parent, so the filesystem mirrors the logical tree.

```
trajectories/
  729eb4ae-root/
    trajectory.jsonl
    blobs/
    008951e3-initialize-leos-subconscious/
      trajectory.jsonl
      blobs/
    30b06a82-generate-next-thought/
      trajectory.jsonl
```

Directory naming: `<hex8>-<slug>`, where:
- `<hex8>` — first 8 hex characters of the trajectory's UUID
- `<slug>` — human-readable label, sanitized to `[a-z0-9._-]`, max 60 chars

## Identifying a trajectory

A trajectory is located by two values:

| Name | Positional | Flag | Env var | Purpose |
|------|------------|------|---------|---------|
| traj_dir | — | `--traj_dir` | `$TRAJ_DIR` | Root trajectories directory |
| traj_id | `[ID]` | — | `$TRAJ_ID` | UUID (or 8-char hex prefix) of the trajectory |

All subcommands accept `[ID]` as an optional positional argument. Falls back to `$TRAJ_ID`. Resolution order: positional > env var.

The resolver (`_resolve_traj_id`) accepts:
1. An exact relative path (e.g. `729eb4ae-root/trajectory.jsonl`)
2. A directory-based path — `$traj_dir/$traj_id/trajectory.jsonl`
3. A basename without `.jsonl` (legacy)
4. A full UUID — extracts first 8 hex chars, searches recursively for a directory named `<hex8>-*`
5. An 8-char hex prefix — recursive directory search
6. Legacy flat file glob: `*_<hex8>_*.jsonl`

The search is recursive, so nested child trajectories are found regardless of depth.

## Step format

Every step is a single-line JSON object with at least these fields:

```json
{
  "type": "<step_type>",
  "step_id": "<uuid>",
  "ts": "<ISO 8601 with milliseconds and timezone>"
}
```

`type` and `step_id` are mandatory. `ts` is added automatically by `traj append`. All other fields depend on the step type.

### Automatic fields

| Field | Added by | Description |
|-------|----------|-------------|
| `step_id` | `traj append` | UUID v4, unique across all trajectories. Preserved if pre-set by caller (e.g. fork steps). |
| `ts` | `traj append` | ISO 8601 timestamp, e.g. `2026-05-16T13:26:06.846-0700` |
| `run_id` | `traj append` (conditional) | Stamped when `SHELLM_RUN_STEP_ID` is in the environment (i.e. the append comes from code executing inside a shellm run) and the step doesn't already carry one. `shellm-run`/`trajectory` steps excluded. See [Run identity](#run-identity-run_id-and-trigger_step). |

## Step types

### Registry

The canonical list of step types. Families:

- **machinery** — written by the shellm run loop (`bin/shellm`). Never
  carry `source`. All except the `shellm-run` header carry `run_id`.
- **structural** — written by the `traj` CLI; manage the trajectory tree.
- **thinker** — written by thinkers dispatched against a mind log. Always
  carry `source` (the thinker's name).
- **conversation** — written by `chat` (a bus client, not a shellm entry
  point). Carry `source: "chat"`.

| Type | Family | Writer | Notes |
|------|--------|--------|-------|
| `trajectory` | structural | `traj new` | First line of every file; its `step_id` is the trajectory's ID |
| `fork` | structural | `traj fork` (nested shellm runs) | Spawns a child trajectory; carries `run_id` when forked from inside a run |
| `merge` | structural | shellm (write-back when a forked child completes); `traj merge` | Carries `content` + `from_traj`/`from_step`/`from_traj_ref`; no `source`; carries `run_id` when written from inside a run |
| `shellm-run` | machinery | shellm loop | Run header; its `step_id` is the run's identity; may carry `trigger_step` + `launched_by` |
| `prompt` | machinery | shellm loop | Carries `run_id` |
| `reasoning` | machinery | shellm loop | Carries `run_id` |
| `shell-output` | machinery | shellm loop | Carries `run_id` |
| `feedback` | machinery | shellm loop | Carries `run_id` |
| `final` | machinery | shellm loop | Carries `run_id`; closes the run |
| `run-summary` | machinery | shellm loop (async) | Carries `run_id` |
| `thought` | thinker | `inner_monologue` | Monologue output; always carries `source`; carries `trigger_step`. (Pre-2026-07-10 logs also used `thought` for forked-child write-backs, now `merge`) |
| `action` | thinker | `inner_monologue` | A thought starting with `action:`; dispatch triggers the actor; carries `trigger_step` |
| `idle` | thinker | `inner_monologue` | Explicit no-op; keeps the `trigger_self` loop alive; carries `trigger_step` |
| `observation` | thinker | `actor` | The actor recording a result to the mind log; carries `run_id` (written from inside the actor's run) |
| `tp-thought` | thinker | thinkers scaffolded by `thinkers create` | Generic thinker output; carries `run_id` when written from inside a run |
| `message` | conversation | `chat send` / `chat reply` / `chat send-file` | Carries `from`/`to`; file variant adds `filename` + `content_b64`; text files keep the body in `content`, binary files use a short marker |
| `delivery` | conversation | a bridge (`slack-bridge`; Telegram and phone chat planned) | Written back for every outbound `message` step the bridge handled; carries `trigger_step` (the message step), `to`, `transport`, `status` (`delivered`, `failed`, `skipped`), and on success `channel`/`ts`/`permalink`, on failure `reason`. Subscribed by no thinker; failed ones show in the monolith's recent stream. See design/outbound_delivery.md |
| `human-msg` | conversation | *(legacy — nothing writes it)* | Still read by `chat repl` for old logs |
| `agent-msg` | conversation | *(legacy — nothing writes it)* | Still read by `chat repl` for old logs |

### Run identity: `run_id` and `trigger_step`

These are guaranteed invariants of the format (writers stamp exact links;
readers must not guess):

- Every execution of the shellm run loop writes exactly one `shellm-run`
  header step. **The header's `step_id` is the run's identity.**
- Every other machinery step the run writes — `prompt`, `reasoning`,
  `shell-output`, `feedback`, `final`, `run-summary` — carries
  `run_id` = that header's `step_id`.
- Many runs may share one trajectory (`shellm --traj <ID>` appends into an
  existing file), and machinery from concurrent runs and thinker steps may
  interleave freely. `run_id` — not file position — is what ties a step to
  its run.
- When a run is launched by a thinker, the `shellm-run` header carries
  `trigger_step` = the `step_id` of the mind-log step that triggered the
  thinker (any step type can trigger), and `launched_by` = the thinker's
  name. Mechanism: the dispatcher exports `SHELLM_LAUNCHED_BY` when
  invoking a step script; step scripts export `SHELLM_TRIGGER_STEP_ID`;
  shellm stamps both on the header and blanks both variables in the
  environment of executed code, so nested runs never inherit a stale
  trigger or launcher. Several runs may share one `trigger_step` (one
  thought can trigger several thinkers).
- Steps a thinker appends *directly* (the monologue's `thought`/`action`/
  `idle`) also carry `trigger_step`, so the dispatch edge exists even when
  no run is involved.
- Steps written by code executing *inside* a run also carry `run_id`:
  shellm exports `SHELLM_RUN_STEP_ID` into the executed code's
  environment, and `traj append` stamps it on any appended step that lacks
  one (`shellm-run` and `trajectory` steps excluded, so a nested run's own
  header and child trajectory never inherit the parent's run). This links
  `observation`, `tp-thought`, `fork`, `merge`, and ad-hoc appends to
  their enclosing run. An explicit `run_id` is never overwritten.
- Machinery steps never carry `source`; readers attribute source-less
  machinery to the shellm loop. `launched_by` is not `source` — readers
  must not conflate them.

Logs written before 2026-07-10 predate these fields. Readers must tolerate
their absence (render such steps as a plain ungrouped stream), never
reconstruct membership heuristically.

### Structural types

These manage the trajectory tree itself.

#### `trajectory`

First step of every `trajectory.jsonl` file. Its `step_id` is the trajectory's ID.

```json
{"type":"trajectory", "step_id":"<uuid>", "ts":"..."}
```

Optional fields (absent for roots):
- `parent_traj` — UUID of the parent trajectory
- `parent_step` — UUID of the fork step in the parent trajectory that spawned this child
- `parent_traj_ref` — relative path from this trajectory's directory to the parent's directory (e.g. `..`)

#### `fork`

Records that a child trajectory was spawned from this point. The fork step's `step_id` is pre-generated and shared with the child trajectory's `parent_step` field for cross-referencing.

```json
{"type":"fork", "child":"<child-traj-uuid>", "child_ref":"<hex8>-<slug>/trajectory.jsonl", "step_id":"<uuid>", "ts":"..."}
```

- `child` — UUID of the child trajectory
- `child_ref` — relative path from this trajectory's directory to the child's `trajectory.jsonl`

#### `merge`

Records that a completed child trajectory's result was merged back into this
one. Written by shellm into the parent trajectory when a forked child run
finishes (the write-back carries the child's final answer as `content`, or
`(max iterations reached)` on failure), and writable manually via
`traj merge <child_id>`. The step points at the child's last step.

```json
{"type":"merge", "content":"<child's final answer>", "from_traj":"<child-traj-uuid>", "from_step":"<child-last-step-uuid>", "from_traj_ref":"<hex8>-<slug>", "step_id":"<uuid>", "ts":"..."}
```

Carries no `source`. Logs written before 2026-07-10 record these
write-backs as `thought` steps with the same cross-reference fields;
readers should treat a `thought` carrying `from_traj` as a legacy merge.

### Reference pattern

All cross-trajectory references use three fields: a trajectory UUID, a step UUID within that trajectory, and a relative path for direct file access.

| Reference | Traj UUID | Step UUID | Relative path |
|-----------|-----------|-----------|---------------|
| Parent trajectory | `parent_traj` | `parent_step` | `parent_traj_ref` |
| Forked child | `child` | — | `child_ref` |
| Source sub-traj | `from_traj` | `from_step` | `from_traj_ref` |
| Spilled stdout | (implicit via `step_id`) | — | `stdout_ref` |
| Spilled stderr | (implicit via `step_id`) | — | `stderr_ref` |

The UUID is the stable identifier; the `_ref` path enables direct file access without searching.

Cross-trajectory references appear in two directions:
- **Upward** (`parent_traj`/`parent_step`/`parent_traj_ref`): on the child trajectory's first step, pointing to the parent that forked it
- **Downward** (`from_traj`/`from_step`/`from_traj_ref`): on `merge` steps written back to a parent trajectory after a sub-run completes, pointing to the sub-trajectory's final step (legacy logs use `thought` steps with the same fields)

### Run lifecycle types

Machinery steps marking the beginning, end, and metadata of a shellm run.
Never carry `source`. All except the `shellm-run` header carry `run_id`
(see [Run identity](#run-identity-run_id-and-trigger_step)).

#### `shellm-run`

The run header, written at the start of every run (immediately after
trajectory creation, or as the first step of a `--traj` run appending into
an existing trajectory). Records how the run was invoked and its
configuration. **Its `step_id` is the run's identity** — every subsequent
machinery step of the run carries it as `run_id`.

```json
{
  "type": "shellm-run",
  "command": "<original command>",
  "workdir": "<path>",
  "model": "<model name>",
  "effort": "<low|medium|high|xhigh|max>",
  "max_iterations": "<N or empty>",
  "max_tokens": "<N or empty>",
  "inactivity_timeout": "<seconds>",
  "context_files": ["<path>", ...],
  "env": {"name":"<env name>", "type":"local|docker", ...},
  "trigger_step": "<uuid, only when launched by a thinker>",
  "launched_by": "<thinker name, only when launched by a thinker>"
}
```

| Field | Description |
|-------|-------------|
| `command` | The full `shellm ...` invocation string |
| `workdir` | Working directory for the run |
| `model` | LLM model used (e.g. `claude-sonnet-4-20250514`) |
| `effort` | Thinking effort level (`low`, `medium`, `high`, `xhigh`, `max`) |
| `max_iterations` | Iteration cap (empty string if unlimited) |
| `max_tokens` | Per-response token limit (empty string if default) |
| `inactivity_timeout` | Seconds before killing idle execution (default: `30`) |
| `context_files` | Array of `-f` file paths passed to the run |
| `env` | Execution environment metadata (local or Docker details) |
| `trigger_step` | Optional. `step_id` of the mind-log step that triggered this run, when launched by a thinker (any step type can trigger) |
| `launched_by` | Optional. Name of the thinker that launched this run (the dispatcher exports `SHELLM_LAUNCHED_BY`) |

#### `prompt`

The user's initial prompt for the run.

```json
{"type":"prompt", "content":"<prompt text>", "run_id":"<shellm-run step_id>"}
```

#### `run-summary`

Auto-generated summary of the run (produced asynchronously by a fast model).

```json
{"type":"run-summary", "tldr":"<one-line summary>", "full_summary":"<longer summary>", "run_id":"<shellm-run step_id>", "model":"<summary model>"}
```

`model` is the model that wrote the summary (the `SHELLM_SUMMARY_MODEL` →
`SHELLM_FAST_MODEL` → run-model resolution) — usually NOT the run's own
model. Absent on steps written before 2026-07-17.

#### `final`

The agent's final answer — the run's output. Closes the run.

```json
{"type":"final", "thought":"<reasoning>", "content":"<answer>", "cmd":"<last code if any>", "run_id":"<shellm-run step_id>"}
```

### Agent reasoning types

Machinery steps recording the agent's thought-action-observation loop.
Never carry `source`; always carry `run_id`.

#### `reasoning`

One iteration of the agent's reasoning, including the code it decided to execute.

```json
{"type":"reasoning", "thought":"<reasoning text>", "cmd":"<bash code>", "run_id":"<shellm-run step_id>"}
```

#### `shell-output`

The result of executing a code block.

```json
{"type":"shell-output", "stdout":"<output>", "stderr":"<errors>", "exit":<code>, "run_id":"<shellm-run step_id>"}
```

When execution timed out:
```json
{"type":"shell-output", "stdout":"...", "stderr":"...", "exit":<code>, "timed_out":true, "feedback":"<inactivity message>", "run_id":"..."}
```

#### `feedback`

System-generated feedback injected into the conversation (e.g. after a timeout).

```json
{"type":"feedback", "content":"<feedback text>", "run_id":"<shellm-run step_id>"}
```

### Thinker types

Written by thinkers — the processes `bin/thinkers` dispatches against a
mind log. Thinker steps always carry `source` (the thinker's name). Steps
a thinker appends directly also carry `trigger_step` (the step that made
the dispatcher fire it); steps written from inside a thinker's shellm run
carry `run_id` instead (stamped by `traj append`).

#### `thought`

The inner monologue's default output. `model` is the model that produced
it (`THINK_MODEL` resolution); the monologue's `action`/`idle` steps carry
it too. Absent on steps written before 2026-07-17.

```json
{"type":"thought", "content":"<thought text>", "source":"inner_monologue", "model":"<think model>", "trigger_step":"<uuid>"}
```

Logs written before 2026-07-10 also used `thought` (with
`from_traj`/`from_step`/`from_traj_ref` and no `source`) for forked-child
write-backs; those are now `merge` steps.

#### `action`

A monologue thought that begins with `action:` — the dispatcher triggers
the actor thinker, which runs `shellm --traj <mind log>`. The resulting
`shellm-run` header points back at this step via `trigger_step`.

```json
{"type":"action", "content":"<description>", "source":"inner_monologue"}
```

#### `idle`

An explicit no-op from the monologue (the model answered `idle`). Emitted
instead of a `thought` so the `trigger_self` loop stays alive without
adding content.

```json
{"type":"idle", "content":"idle", "source":"inner_monologue"}
```

#### `observation`

The actor recording a result or meaningful intermediate finding to the
mind log.

```json
{"type":"observation", "content":"<result>", "source":"actor", "run_id":"<shellm-run step_id>"}
```

#### `tp-thought`

Generic thinker output — the `thinkers create` scaffold instructs new
thinkers to write this type.

```json
{"type":"tp-thought", "content":"<thought text>", "source":"<thinker name>"}
```

### Conversation types

Produced by `chat` for messaging on a mind log. `chat` is a bus client, not
a shellm entry point: `chat send` is one `traj append`.

#### `message`

A message between named parties (human or agent).

```json
{"type":"message", "content":"<message>", "from":"<sender>", "to":"<recipient>", "source":"chat"}
```

The file-transfer variant (`chat send-file`) always adds `"filename"` plus `"content_b64"` (standard base64 of the file bytes). Text files also keep the file body in `"content"` so Slack and web chat still deliver those contents. Binary files use a short marker (`[file: name]`) because JSON `content` cannot hold raw bytes:

```json
{"type":"message", "content":"hello file", "filename":"note.txt", "content_b64":"<standard-base64>", "from":"<sender>", "to":"<recipient>", "source":"chat"}
```

```json
{"type":"message", "content":"[file: fig.png]", "filename":"fig.png", "content_b64":"<standard-base64>", "from":"<sender>", "to":"<recipient>", "source":"chat"}
```

An optional `"reply_to":"<step_id>"` names the message step this one
answers, making "has this message been answered" a fact in the log rather
than an ordering heuristic. `chat reply` stamps it at the transport: the
caller may pass `--reply-to <step_id>` explicitly, otherwise the stamp is
inferred as the latest message from the recipient to the sender that no
stamped reply has answered yet (a reply that answers nothing stays
unstamped). Stamping at the transport means the fact does not depend on
which code path — or which model — sent the reply. Readers that don't know
the field ignore it.

#### `human-msg` / `agent-msg` (legacy)

Predecessors of `message` — a human message into the thought stream and
the agent's reply. Nothing writes them anymore; `chat repl` still reads
them so old logs render.

```json
{"type":"human-msg", "content":"<message>"}
{"type":"agent-msg", "content":"<message>"}
```

## Blob spilling

When `stdout` or `stderr` exceeds 4096 bytes (configurable via `$SHELLM_STDOUT_INLINE_LIMIT`), the full content is written to a blob file and the inline value is truncated.

Blob files live in a `blobs/` directory inside the same trajectory directory as the `trajectory.jsonl` that references them.

### Blob file naming

```
blobs/<step_id>-<blob_id>.stdout
blobs/<step_id>-<blob_id>.stderr
```

`blob_id` is a zero-padded hex counter per step (e.g. `000000`).

### Truncated step fields

When a field is spilled, three extra fields are added to the step:

```json
{
  "stdout": "<first 4096 bytes>",
  "stdout_ref": "blobs/<step_id>-<blob_id>.stdout",
  "stdout_bytes": 52341,
  "stdout_truncated": true
}
```

`traj show <step_id> --full` restores the full content from the blob.

## Tree structure

Trajectories form a tree via `fork` steps and `parent_traj` fields:

- A **root** trajectory has no `parent_traj` field on its first step.
- A **child** trajectory has `"parent_traj":"<parent-uuid>"` and `"parent_step":"<fork-step-uuid>"` on its first step, and the parent has a corresponding `"fork"` step with `"child":"<child-uuid>"`.
- When a child completes, the parent records a `"merge"` step with `from_traj`/`from_step`/`from_traj_ref` pointing to the child's final step.

The filesystem mirrors this: child trajectory directories are nested inside their parent's directory.

`traj list` renders this tree:

```
>>> 729eb4ae: hello world (5 steps)
├── acce682d: sub task (3 steps)
│   └── f362b564: deep subtask (1 steps)
└── 248d5f75: second child (1 steps)
```

`>>>` marks the trajectory you're viewing from.

`traj list --steps` expands each trajectory to show individual steps inline, with child trajectories rendered under their fork steps:

```
>>> 729eb4ae: hello world (7 steps)
    ├── aaa11111 [shellm-run] shellm 'hello world'
    ├── aaa11112 [prompt] hello world
    ├── aaa11113 [fork] -> acce682d-...
    │   └── acce682d: sub task (3 steps)
    │       ├── bbb11111 [prompt] do the sub task
    │       └── bbb11112 [final] done
    ├── aaa11114 [thought] (from acce682d)
    └── aaa11115 [final] Hello!
```

## Expected step ordering

A complete shellm run follows this order:

```
trajectory                      # created by traj new (absent for --traj runs)
shellm-run                      # run header; its step_id is the run id
prompt                          # the user's request        (run_id)
run-summary                     # async, may appear at any point after prompt (run_id)
reasoning → shell-output        # repeated per iteration    (run_id)
final                           # the agent's answer (terminates the loop, run_id)
```

The `reasoning → shell-output` pair repeats for each iteration. If the LLM responds without a code block, a `final` step is written directly (no `reasoning`/`shell-output` pair for that iteration).

The `run-summary` step is generated asynchronously and may land anywhere after the `prompt` step — often between `prompt` and the first `reasoning`, but sometimes after `final`.

**Ordering is per run, not per file.** With `shellm --traj <ID>` a run
appends its machinery into an existing trajectory, so one file can hold
many runs, interleaved with each other and with concurrent thinker and
conversation steps. The order above holds among the steps sharing a
`run_id`; readers must group by `run_id`, not by position.

## CLI reference

```
traj <command> [ID] [options]
```

All commands accept `[ID]` as an optional positional argument (trajectory ID, UUID, or 8-char hex prefix). Falls back to `$TRAJ_ID`. All commands also accept `--traj_dir DIR`.

| Command | Syntax | Description |
|---------|--------|-------------|
| `new` | `new [--slug TEXT] [--field key=val ...]` | Create a new trajectory. Outputs UUID then relative dir path. |
| `append` | `append [ID] [--field key=val ...]` | Append a step from stdin JSON or `--field` flags. |
| `fork` | `fork [ID] [--child CHILD_ID] [--slug TEXT] [--step-id UUID]` | Append a fork step. Auto-creates child traj if `--child` omitted. |
| `merge` | `merge <child_id> [ID] [--field key=val ...]` | Append a merge step from a completed child. |
| `show` | `show <id> [--full] [--field F]` | Show a trajectory or step by ID. Searches all files in traj_dir. |
| `tail` | `tail [ID] [-n N] [-f] [--type T1,T2]` | Stream recent steps (like `tail` for JSONL). |
| `search` | `search <pattern> [ID] [--field F] [-i] [-C N] [-E]` | Search step fields for a pattern. |
| `count` | `count [ID]` | Print step count. |
| `last` | `last [ID] [--field KEY]` | Print the last step. `--field` extracts one field. |
| `cat` | `cat [ID] [--filter F] [-r] [--raw]` | Output all steps (formatted or JSONL). |
| `exists` | `exists [ID]` | Exit 0 if trajectory exists and has steps. |
| `list` | `list [ID] [--parents N\|all] [--children N\|all] [--steps] [--json]` | List tree as ASCII. `--steps` expands inline. |
| `isroot` | `isroot [ID]` | Exit 0 if trajectory has no parent. |
| `root` | `root [ID]` | Walk up to root and print its directory name. |

## Example: complete trajectory

```
729eb4ae-root/
  trajectory.jsonl
  blobs/
  acce682d-sub-task/
    trajectory.jsonl
```

`729eb4ae-root/trajectory.jsonl`:
```jsonl
{"type":"trajectory","step_id":"729eb4ae-2a49-4b41-9db6-8ff3aa500d2a","ts":"2026-05-16T13:26:06.846-0700"}
{"type":"shellm-run","command":"shellm 'echo hello'","workdir":"/tmp/work","model":"claude-sonnet-4-20250514","effort":"high","max_iterations":"","max_tokens":"","inactivity_timeout":"30","context_files":[],"env":{"name":"local","type":"local"},"step_id":"aaa11111-0000-0000-0000-000000000001","ts":"2026-05-16T13:26:06.850-0700"}
{"type":"prompt","content":"echo hello","run_id":"aaa11111-0000-0000-0000-000000000001","step_id":"aaa11111-0000-0000-0000-000000000002","ts":"2026-05-16T13:26:06.855-0700"}
{"type":"run-summary","tldr":"Ran echo command","full_summary":"","run_id":"aaa11111-0000-0000-0000-000000000001","step_id":"aaa11111-0000-0000-0000-000000000003","ts":"2026-05-16T13:26:07.100-0700"}
{"type":"fork","child":"acce682d-1234-5678-9abc-def012345678","step_id":"aaa11111-0000-0000-0000-000000000004","ts":"2026-05-16T13:26:08.000-0700"}
{"type":"merge","content":"Sub task done","from_traj":"acce682d-1234-5678-9abc-def012345678","from_step":"bbb11111-0000-0000-0000-000000000002","from_traj_ref":"acce682d-sub-task","step_id":"aaa11111-0000-0000-0000-000000000005","ts":"2026-05-16T13:26:09.000-0700"}
{"type":"final","thought":"Got the output, returning it.","content":"hello","run_id":"aaa11111-0000-0000-0000-000000000001","step_id":"aaa11111-0000-0000-0000-000000000006","ts":"2026-05-16T13:26:10.000-0700"}
```
