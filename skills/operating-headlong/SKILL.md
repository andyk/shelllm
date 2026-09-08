---
name: operating-headlong
description: Operates Headlong identities, dispatchers, chat, memory, trajectories, context, and skills safely. Use for choosing between llm, shellm, and a persistent identity; routine identity work; state inspection; or failure triage.
---

# Operating Headlong

Operate the persistent identity framework safely; use `shellm` only for its
bounded recursive shell-execution role.

## Choose a runtime

- Use `llm` for one completion with no command execution.
- Use `shellm` for bounded exploration or analysis that needs shell commands.
- Use a Headlong identity for an ongoing assistant or worker that needs chat,
  memory, skills, a trajectory, and a dispatcher.
- Keep job state, authorization, idempotency, approvals, and external outcomes
  in the integrating application. Identity persistence does not provide them.

## Locate the installation

Use `HEADLONG_HOME`, then legacy `SHELLM_HOME`, when explicitly set. Otherwise
use `~/.headlong`, falling back to `~/.shellm` only when the former is absent
and the latter exists. The current `persona` wrapper does not make that legacy
fallback automatically: set `HEADLONG_HOME` explicitly for a legacy install.
Resolve the checkout from `HEADLONG_APP_DIR`, then `SHELLM_APP_DIR`, then the
wrapper's own source checkout, `$state_home/app_dir`, or `$state_home/app`.
Never print `.env` or secret values.

When available, read `$checkout/docs/operating-headlong.md` for the full human
guide, `$checkout/docs/install.md` for lifecycle and recovery, and
`$checkout/docs/shellm.md` for the execution engine. This procedure remains
usable without those files.

## Prefer the persona interface

Use the installed identity-name command or `persona <name>` from any directory:

```bash
persona <name> status
persona <name> say "message"
persona <name> stop
persona <name> start
persona <name> dash
persona <name> shell
```

Start with `status`; it checks live PIDs and thinker state. `status.json` is an
install snapshot, not live authority. `start` starts the monolith and responder
and queues their wakeups. Run stop/restart externally, never from inside the
identity's own dispatcher tree.

## Enter an identity safely

Prefer `persona <name> shell`, then `exit`. Direct `identity shell <name>` does
not preload checkout/state-home `.env`; use only with those defaults already
loaded. Do not nest identity shells. Do not source `activate` bare: model and key
defaults may be wrong. Automation that must activate manually must preserve
existing environment values, load checkout `.env`, then state-home `.env`, then
source `.identities/<name>/activate`; activation loads identity `.env`.

The activated environment selects `MEM_DIR`, `SKILLS_DIR`, kernel skills,
`TRAJ_DIR`, root `TRAJ_ID`, thinker directories, chat config, and model.

## Inspect and operate durable state

The checkout's `.identities/<name>/` owns the identity. Treat it as sensitive.
Key sources are:

- `trajectories/`: authoritative JSONL history and blobs. Derived indexes are
  rebuildable. Inspect with `traj tail -n 20`, `traj search`, `traj show`, and
  `traj check`. Avoid append/fork/merge/`check --fix` unless mutation is intended.
- `memories/`: curated durable knowledge, not a job ledger. Use `mem list`,
  `mem show`, `mem add --type TYPE`, `mem edit`, and `mem forget`. Prefer
  `mem prefilter` for a no-model candidate check; `mem search` costs a call.
- `skills/` and `kernel/`: on-demand and always-loaded procedures. Use
  `skills list`, `skills list --all`, and `skills show`. Review unfamiliar
  skills before showing them because marked evaluation blocks may execute.
- `run/dispatcher.pid` and `run/logs/`: live process evidence and thinker logs.
- `chat/.chatrc`: operator sender config. `chat send` requires `--from` or
  `default_send_from`; `persona` seeds `operator` when absent.

Messages append to the root trajectory. Human sends use `chat send`; identity
responses use `chat reply`. Self-addressed sends are rejected to prevent loops.
`context --head 1 --tail 30` renders history as model messages but does not own
or alter the trajectory.

## Triage failures

1. Run `persona <name> status` and separate mind, model, and dashboard failures.
2. Inspect state-home `logs/init.log` and `logs/web.log`, then identity
   `run/logs/`; redact user data before sharing.
3. Validate a PID with `kill -0`, and confirm checkout via state-home `app_dir`.
4. Check model, endpoint, credential presence, quota, and rate limit without
   revealing secrets. The persona status reports recorded LLM health failures.
5. Run `traj check`; back up state before any repair.
6. Restart a stopped mind externally with `persona <name> start`. A dashboard
   failure need not mean messaging failed.
7. `persona <name> bugreport` creates a scrubbed archive; inspect it before
   disclosure because trajectories and memories contain user data.

## Enforce boundaries

- Prefer Docker or equivalent isolation for model-generated commands.
- Do not expose host Docker control or broad host services to generated code.
- Use least-privilege, revocable, spend-capped credentials.
- Persistent thinkers and model-assisted searches incur ongoing cost.
- Put side effects behind application-owned permission and approval checks.
- Back up identity state before import, deletion, repair, or bulk edits.
- Consult each command's `--help` and current source before uncommon or
  destructive operations; do not infer flags.
