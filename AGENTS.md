# Operating Headlong as a coding agent

This file is for coding agents (Claude Code, Cursor, and similar). It
covers installing Headlong without a tty, checking that it is healthy, and
the sharp edges that are not obvious from the code.

Naming: **Headlong** is the agent framework — identities, thinkers, the
mind log, bridges, the dash. **shellm** is one tool inside it: the
CLI implementation of Recursive Language Models in bash (`bin/shellm`),
plus its run machinery (`shellm-docker`, `shellm-explore`). Use "Headlong"
for the system and "shellm" only for that tool. Framework commands are
`headlong-*` (`headlong-init`, `headlong-web`, ...; the old `shellm-*` names
remain as symlinks) and framework env vars are `HEADLONG_*` (legacy
`SHELLM_*` spellings still honored). The state home defaults to
`~/.headlong`, falling back to `~/.shellm` when only that exists (so
pre-rename installs keep their state); explicit `HEADLONG_HOME` or
`SHELLM_HOME` overrides both. Systemd units are `headlong-*`; a box provisioned before
the rename is migrated once with `deploy/migrate-units.sh` (see
deploy/DEPLOY.md). What deliberately keeps the `shellm` name: the
`/opt/shellm` deploy path, the `shellm` and `shellm-telegram` UNIX users,
`~shellm/.shellm`, the per-identity `.shellm/` subdirectory, the
`~/.headlong-thinkers` template dir that install.sh seeds, and the
`*.shellm.net` domains. If you take one of those on, or any other
structural change to a live box, read `deploy/MIGRATIONS.md` first — it
lists the couplings that fail *silently*.

Headlong creates a persistent identity whose mind is a loop of LLM calls
run by a dispatcher. The identity has a name (default `ada`), and that
name becomes a shell command. A local web dashboard shows the mind's
trajectory.

## Install without a tty

With no tty the installer asks nothing; every answer comes from an
environment variable or a default. A key must be in the environment:

```bash
export OPENROUTER_API_KEY=sk-or-...   # or ANTHROPIC_/OPENAI_/GEMINI_API_KEY
curl -fsSL https://headlong.ai/install.sh | bash
```

Optional variables: `HEADLONG_IDENTITY_NAME`, `HEADLONG_IDENTITY_VIBE`,
`HEADLONG_IDENTITY_FOCUS`, `HEADLONG_IDENTITY_USER` (the interview answers),
`SHELLM_MODEL` (otherwise picked per provider; a tool var, so no HEADLONG_
spelling), `HEADLONG_NO_DASH=1`,
`HEADLONG_NO_THINKERS=1`. The installer never uses sudo. In a container as
root it apt-installs its own dependencies.

Warning: the installer symlinks tools into `~/.local/bin`. If those names
already link into a development checkout, the one-liner repoints them to
`<state-home>/app`. Do not run it against a HOME you did not create for it.

## Check the outcome

The installer writes `status.json` in the state home (`~/.headlong`, or
`~/.shellm` on pre-rename installs) at the end of every run:

```bash
jq -r '.identity, .mind.status, .dash.status, .dash.url' ~/.headlong/status.json
```

`mind.status` and `dash.status` are `ok`, `failed`, or `skipped`. The
file is a snapshot of that run; the live source of truth is the pid files
it names (`.mind.pid_file`, `.dash.pid_file`). `<name> status` prints the
same picture for humans.

`dash.url` works from wherever Headlong is installed. When `container` is
true, the URL is container-internal: from the host, use localhost with
whatever host port was published (`docker run -p <host>:8080`). The
container cannot know that number.

## Talk to the identity

```bash
ada hello                  # bare words are a message; waits for the reply
ada say "longer message"   # same, explicit
ada status                 # mind and dash state
ada stop / ada start       # pause and resume the mind
ada dash                   # print or open the dashboard URL
ada shell                  # a shell inside the identity's environment
```

If the name collides with an existing command, the installer refuses to
stomp it and everything is reachable as `persona <name> ...` instead.
Replies take 15 to 45 seconds while the monolith thinker wakes.

## Where things live

- `~/.headlong/` — state root (`HEADLONG_HOME`, legacy `SHELLM_HOME`;
  pre-rename installs use `~/.shellm`): `.env` (key + model),
  `status.json`, `logs/` (`init.log`, `web.log`), `run/web.pid`,
  `app_dir` (path to the checkout).
- `~/.headlong/app/` — the checkout, when installed by the one-liner.
- `~/.local/bin/` — the installed tools (symlinks for the one-liner).
- `~/.skills/core-skills/` and `~/.headlong-thinkers/` — the bundled skills
  and thinker templates that new identities are seeded from.
- `<app>/.identities/<name>/` — the identity: persona, memories,
  trajectory, `run/dispatcher.pid`, and its `activate` script.

## Sharp edges

- Any script that sources an identity's `activate` must first load
  `<app>/.env` and then the state home's `.env` (see `_load_env` in
  `tools/persona`). Sourcing `activate` bare makes the think model fall
  back to an expensive default with no key.
- `chat send` dies without a sender name. It comes from the identity's
  own chatrc (`<identity>/chat/.chatrc`, seeded by the installer), not
  from a `.chatrc` in the current directory.
- The installer is idempotent: re-running keeps the key and identity,
  skips the interview, restarts the mind and dashboard, and never blocks
  on a prompt once a key has worked, so unattended re-runs (a restarted
  container) are safe.
- The dashboard binds localhost by default and `0.0.0.0` in a container.
  A failed dashboard does not fail the install; check `dash.status` in
  `status.json` and `<state-home>/logs/web.log`.
- Responses mode (`SHELLM_API_FORMAT=responses`) keeps its continuation
  state per process: response ids and the replay chain live in the run's
  temp dir and vanish with it, and a `--resume` starts a fresh chain from
  the trajectory. Only `SHELLM_RESPONSES_CONVERSATION` is durable across
  runs (the id is written to the `shellm-run` header row). The knobs and
  their interplay are in the Responses sections of
  [docs/shellm.md](docs/shellm.md); the contracts are
  design/responses-api.md and design/responses-lifecycle.md.
