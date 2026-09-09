# Operating Headlong

Headlong provides persistent identities, background thinkers, a trajectory,
memory, skills, chat, and a dashboard. `shellm` is one execution tool inside
Headlong: it lets a model inspect data and run bounded shell commands.

## Choose the smallest runtime that fits

| Need | Use | Why |
|---|---|---|
| One completion, with no command execution | `llm` | A direct model call with the least machinery |
| A bounded investigation that may run code | `shellm` | A run with a work directory and run record; choose an actual sandbox separately |
| A continuing assistant or background worker | A Headlong identity | Durable trajectory, memory, skills, messaging, and dispatcher |

Use `llm` for extraction, classification, rewriting, or a single answer. Use
`shellm` for standalone exploration, repository analysis, or data work where
the model needs a shell. Use an identity for a user-facing assistant or a
subordinate worker whose ongoing tasks, permissions, and lifecycle are owned by
the application around it. Persistence does not replace authorization, job
state, idempotency, approval, or retry logic in that application.

The complete installation choices are in [Installing Headlong](install.md).
The engine, sandbox, run explorer, and direct `llm` interface are documented in
[the shellm guide](shellm.md).

## Everyday identity workflow

The installer normally creates a command named after the identity. If that
name collides with another command, use `persona <name>` instead.

```bash
ada status                 # read-only health summary
ada hello                  # send one message and wait briefly
ada say "review this plan" # explicit one-message form
ada                        # interactive chat
ada stop                   # pause mind and dashboard
ada start                  # resume monolith, responder, and dashboard
ada dash                   # print/open the dashboard URL
ada shell                  # advanced: identity-aware subshell
```

`persona <name> status` and the other forms work from any directory. Prefer
them over manually activating an identity: `persona` locates the checkout,
loads configuration in the right order, activates the identity, and ensures
chat has a sender.

`status` checks the live dispatcher PID and dashboard PID, then prints thinker
status. The install-time `status.json` is only a snapshot. Its named PID files
are the live source of truth. After `stop`, finish any external work before
assuming it completed: stopping drains in-flight thinker work for a bounded
period and may then terminate it.

Do not have a thinker stop and restart its own dispatcher. The stop also kills
the caller, so the restart cannot run. Perform lifecycle operations from an
operator process outside that identity's dispatcher tree. The CLI refuses an
unsafe self-stop unless explicitly overridden.

## State, configuration, and ownership

`HEADLONG_HOME` selects the state home; legacy `SHELLM_HOME` is the next
explicit override. Otherwise Headlong uses `~/.headlong`, except that an older
installation with only `~/.shellm` continues using that directory. The state
home contains `.env`, `status.json`, `logs/`, `run/`, and `app_dir` (the
recorded checkout path). A one-line `app_dir` file is the reliable way for an
installed tool or skill to find source documentation.

The current `persona` wrapper defaults directly to `~/.headlong`; on a legacy
installation explicitly set `HEADLONG_HOME="$HOME/.shellm"` so its state path
matches the other tools. Its checkout resolution prefers an explicit app-dir
override, then its own source checkout, then the recorded `app_dir` and `app/`.

The checkout owns `.identities/<name>/`. Important identity state includes:

```text
info.txt                  identity metadata and root trajectory
activate                  generated environment setup
.env                      optional identity-specific configuration
memories/                 durable memory Markdown files
skills/ and kernel/       available and always-loaded skills
trajectories/             authoritative JSONL event history and blobs
chat/.chatrc              operator sender name
run/dispatcher.pid        live mind PID
run/logs/                 thinker logs
.shellm/ and workdir/     execution state and working files
```

The trajectory is the authoritative interaction and thought history. Derived
message or deferral indexes can be rebuilt and are not the source of truth.
Memories are curated durable facts, preferences, objectives, and notes; they
should not be used as a job ledger. Skills are procedures presented to the
mind, with kernel skills loaded on every wake and other eligible skills loaded
on demand. The application integrating an identity remains responsible for
requests, permissions, side-effect policy, and externally durable outcomes.

Treat all of these as sensitive user data. Back them up together when
persistence matters, restrict filesystem access, and never commit `.env`,
identity state, trajectories, or bug-report archives.

## Environment loading

For routine use, use `persona <name> shell`. Direct `identity shell <name>`
sets identity paths but does not preload checkout/state-home configuration;
use it only when those defaults are already loaded. If automation must
source `activate`, first load the checkout `.env`, then the state-home `.env`,
without overriding variables already supplied by the process; only then source
the identity's generated `activate` file. The activation script subsequently
loads the identity `.env`. Sourcing `activate` alone can select an unintended
model or omit credentials.

```bash
persona ada shell
# work with chat, mem, traj, context, and skills
exit
```

Do not nest identity shells. Exit the current one first. Explicit process
environment values take precedence over file defaults. For thinker steps, the
fallback sequence is identity `.env`, working-directory `.env`, the Headlong
state-home `.env`, then legacy `~/.shellm/.env`; existing values still win.
Keep model choice and credentials deliberate rather than relying on fallback.

## Chat and sender identity

`chat` requires an activated identity. Messages always append to the root
trajectory, even when sent from a fork. A human/operator send needs a sender:

```bash
chat send --from operator "please summarize the latest findings"
chat history 20
```

Persona commands that activate the identity (such as `say` and `status`) seed
`default_send_from=operator` when absent. Direct `chat send`
fails rather than inventing a sender. Use `--from` and `--to` when attribution
must be explicit. An identity responding to another participant should use
`chat reply`; self-addressed `chat send` is rejected to prevent reply loops.
Use `chat --help` for bridge metadata, threaded history, files, and follow-ups.

## Memory, trajectory, context, and skills

Run these inside `ada shell` (or another correctly activated environment).
Replace `MEMORY_ID`, `STEP_OR_TRAJECTORY_ID`, and `SKILL_NAME` with values
returned by the corresponding inspection commands:

```bash
mem add --type fact "The deployment window is Tuesday."
mem list --type fact -s
mem show MEMORY_ID
mem search "deployment window"     # model-assisted; costs a call

traj tail -n 20
traj search "deployment" -i
traj show STEP_OR_TRAJECTORY_ID
traj check                         # read-only validation

context --head 1 --tail 30         # JSON model-message view
skills list
skills show SKILL_NAME
```

Use `mem edit <id> ...` to correct and `mem forget <id>` to delete only after
confirming the target. `mem prefilter <query>` is a no-model candidate check;
`mem search` asks a model to rank candidates. Memory files are Markdown with
frontmatter, but use `mem` so IDs and metadata stay valid.

Use `traj tail`, `search`, `show`, and `path` for inspection. `traj append`,
`fork`, `merge`, and `check --fix` mutate history; reserve them for deliberate
maintenance or application code. Large step fields may live in trajectory
blob storage. `context` renders selected trajectory rows into model messages;
it does not own the underlying history.

`skills list` shows eligible skills; `skills list --all` also shows skills
whose requirements are unmet. `skills show` can execute explicitly marked
evaluation blocks in a skill, so review unfamiliar skill source before loading
it. Installation and promotion operations change what the mind can do; use
`headlong-skills --help`, review the source and requirements, and make those
changes as an operator rather than from untrusted model output.

## Failure triage

1. Run `<name> status`. Distinguish a stopped dispatcher from a failed model
   call or dashboard-only failure.
2. Read the state-home `logs/init.log` and `logs/web.log`, then the identity's
   `run/logs/`. Do not paste logs publicly without checking for user data.
3. Confirm the checkout with `cat "$HEADLONG_HOME/app_dir"` (using the resolved
   state home), and inspect `.identities/<name>/run/dispatcher.pid` with
   `kill -0 <pid>` rather than trusting stale snapshots.
4. Check model, endpoint, key presence, quota, and rate limits without printing
   secrets. `persona status` reports the last recorded LLM health failure.
5. Validate history with `traj check`; do not use `--fix` until a backup exists.
6. If the dashboard alone failed, inspect `web.log`; identity messaging can
   still work. If the mind is stopped, restart it externally with `<name> start`.
7. For a shareable diagnostic archive, use `<name> bugreport`, inspect its
   contents locally, and disclose only what is appropriate. Scrubbing reduces
   risk but is not a substitute for review.

## Safety and cost boundaries

- Headlong and `shellm` can execute model-generated commands. Prefer Docker or
  another sandbox; never weaken isolation merely to get a run unstuck.
- A container that can reach a host model endpoint may also reach other host
  services. Limit network paths and require authentication on sensitive APIs.
- Give identities least-privilege credentials and filesystem access. Keep
  production side effects behind application-owned authorization and approval.
- Use dedicated, revocable, spend-capped model keys. Persistent thinkers call
  models continuously; `mem search` and other helpers may make additional calls.
- Avoid exposing host Docker control to generated code. It effectively grants
  host-level power.
- Stop the identity before maintenance that assumes a quiescent state, and back
  up durable state before repair, import, deletion, or bulk edits.

For installation, upgrades, exports, bug reports, and uninstall procedures,
continue with [Installing Headlong](install.md). For bounded code execution,
provider options, run summaries, and sandbox details, use
[shellm — the RLM engine](shellm.md). The command's `--help` and current source
remain authoritative when a checked-out version differs from these guides.
