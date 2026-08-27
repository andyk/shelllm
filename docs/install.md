# Installing Headlong

The short version is in the [README](../README.md). This page has every
variant.

## The one-liner

```bash
curl -fsSL https://headlong.ai/install.sh | bash
```

The installer first looks for Docker, because the agent writes and runs
real shell commands and Docker is the sandbox for them.

- With Docker running, it asks where the agent should live: fully inside
  a Docker container (the default, described in the next section), on
  your machine with the agent's shell commands still sandboxed in Docker,
  or, not recommended and behind another typed `yes`, on your machine
  with no sandbox at all. The unsandboxed choice sticks across re-runs;
  set `HEADLONG_UNSANDBOXED=0` in `~/.headlong/.env` and re-run
  `headlong-init` to turn the sandbox on.
- With Docker installed but not running, it asks you to start Docker and
  checks again.
- With no Docker at all, it stops and warns you: the agent's commands
  would run directly on your machine as your user. You must type the word
  `yes` to continue without a sandbox.

On the host path it then clones the repo to `~/.headlong/app`, symlinks
the tools into `~/.local/bin`, asks for an LLM API key, and runs a short
optional interview: a name, a few words of personality, what they should
think about when idle. The answers become the agent's core identity and
first memories. Then their mind starts and the dashboard opens. Their
name becomes a command:

```bash
ada                  # chat with them
ada hello            # one message, wait for the reply
ada stop / ada start # pause / resume their mind
ada dash             # open the dashboard
ada bugreport        # bundle logs + trajectory (keys scrubbed) for a bug report
```

Use a dedicated, spend-capped API key: the agent executes real shell
commands and calls the LLM continuously.

Re-running the one-liner updates everything in place. The installer never
uses sudo, and the piped script only clones the repo and re-runs the
installer from the checkout, so what executes is the same code you can
read here. To read first:

```bash
curl -fsSLO https://headlong.ai/install.sh
less install.sh && bash install.sh --init
```

## Docker: a long-lived agent

The same installer works inside a container. Nothing touches your
machine, and the agent's shell commands run in the container too. When
the one-liner above finds Docker running, it offers this flow and runs
the command below for you; pasting it yourself does the same thing. The
installer apt-installs its own dependencies (as root in a fresh
container) and the dashboard binds `0.0.0.0` so the published port works.

```bash
docker run -it --name headlong --restart unless-stopped -p 8080:8080 buildpack-deps:curl \
  bash -c 'curl -fsSL https://headlong.ai/install.sh | bash; exec bash'
```

Paste your key, answer the interview, then open http://localhost:8080 on
your host to watch the mind run. Typing `exit` does not end the world:
Docker restarts the container in the background, the installer re-runs
prompt-free (it keeps your key and identity and pulls the latest code),
and the mind and dashboard come back up on their own.

Day-to-day:

```bash
docker exec -it headlong bash -l   # drop back into your agent's world
docker stop headlong               # pause everything
docker start headlong              # resume
docker rm -f headlong              # delete the agent and its whole world
```

Pasting the run command a second time fails with "name headlong already in
use". That means your agent already exists; `docker exec` is how you get
back to it.

For a throwaway sandbox instead, drop `--name` and `--restart` and add
`--rm`. Exiting the shell then deletes everything.

## Non-interactive install (CI and coding agents)

With no tty, every question falls back to an environment variable or a
default, so a script or a coding agent can install with no interaction:

```bash
export OPENROUTER_API_KEY=sk-or-...   # or another provider's *_API_KEY
export HEADLONG_IDENTITY_NAME=ada       # optional; the interview's answers
export HEADLONG_IDENTITY_VIBE="curious, warm, and plainspoken"
export HEADLONG_IDENTITY_FOCUS="learning how their own mind works"
export HEADLONG_IDENTITY_USER="I'm Sam, a programmer trying Headlong out"
curl -fsSL https://headlong.ai/install.sh | bash
```

A provider credential must be in the environment; everything else is optional.
`HEADLONG_NO_DASH=1` and `HEADLONG_NO_THINKERS=1` skip those parts.

For Amazon Bedrock, use a Bedrock API key and the Region where it was created:

```bash
export AWS_BEARER_TOKEN_BEDROCK=...
export AWS_REGION=us-east-1
# Optional: Mantle OpenAI instead of the default Bedrock Claude model
export SHELLM_MODEL=openai.gpt-5.6-sol
curl -fsSL https://headlong.ai/install.sh | bash
```

`AWS_ACCESS_KEY_ID` plus `AWS_SECRET_ACCESS_KEY` (and, for temporary
credentials, `AWS_SESSION_TOKEN`) can replace the Bedrock API key. The curl
used for SigV4 authentication must be version 7.75 or newer.

An AWS CLI profile is the durable choice when credentials come from SSO or a
`credential_process`; Headlong asks AWS CLI for fresh credentials on each
model call and persists the profile's configured Region:

```bash
export AWS_PROFILE=codex-bedrock
curl -fsSL https://headlong.ai/install.sh | bash
```

Profile-backed installs stay on the host because a standalone agent container
cannot safely invoke a host credential process. Generated shell commands are
still Docker-sandboxed. Use `AWS_BEARER_TOKEN_BEDROCK` for the fully
containerized install option.

With no tty there is nobody to answer the sandbox question, so on a
machine without a working Docker daemon the install stops unless
`HEADLONG_UNSANDBOXED=1` is set. Setting it accepts that the agent's
shell commands run directly on the machine. Inside a container it is not
needed; the container already is the sandbox.

When Docker is present, the installer writes `SHELLM_REQUIRE_DOCKER=1`
to `~/.headlong/.env`. From then on, a Docker daemon that stops answering
is a hard error for the agent's runs instead of a silent fall back to
running on the host. Set it to `0` there if you want the old best-effort
behavior.

The installer writes `status.json` in the state home (`~/.headlong`) with
the outcome:

```bash
jq -r '.mind.status, .dash.status, .dash.url' ~/.headlong/status.json
```

[AGENTS.md](../AGENTS.md) covers operating a running identity: paths,
logs, health checks, and the sharp edges.

## From a checkout

```bash
git clone https://github.com/laude-institute/headlong.git
cd headlong
./install.sh            # add --init to also bootstrap an identity + dash
```

This copies the tools in `bin/` and `tools/` to `~/.local/bin`, the core
skills to `~/.skills/core-skills`, the bundled thinker templates to
`~/.headlong-thinkers`, and builds the Rust TUI if cargo is present.

`headlong-init --dry-run` walks the Docker sandbox question interactively
without writing or starting anything, which is handy for seeing what the
install will ask on a given machine. Setting
`HEADLONG_FAKE_DOCKER=ok|down|missing` fakes the Docker probe and
`HEADLONG_NO_TTY=1` forces the no-terminal behavior, so every path can be
rehearsed anywhere. Use `--symlinks` to
symlink instead (edits take effect without reinstalling), or
`--prefix /usr/local/bin` for a different location.

## Reporting a bug

If something goes wrong, run

```bash
ada bugreport        # or: persona <name> bugreport
```

and attach the `.tgz` it prints (it lands in your home directory) to a
GitHub issue or a message to us. The bundle holds what we need to see what
happened: the agent's trajectory and rollups, memories, thinker logs, the
dash and install logs, and a `report.txt` with versions and status. Your
`.env` is not included, and API keys or other credential-looking values are
scrubbed before the file is written: keys and tokens keep their first and
last four characters (`<redacted sk-o...cdef>`) so two keys can be told
apart, passwords are masked whole. The agent's
`workdir/` is left out unless you pass `--include-workdir`. Look inside
first if you want: `tar tzf <file>` lists it; unpack it with `tar xzf
<file>` and read `headlong-bugreport-*/report.txt` for the summary.

Where things live, if you would rather pick files by hand: the state home is
`~/.headlong/` (`logs/`, `status.json`, `.env`), the checkout is
`~/.headlong/app/`, and the agent is `~/.headlong/app/.identities/<name>/`
with the root trajectory at `trajectories/*-root/trajectory.jsonl` and the
thinker logs under `run/logs/`.

## Stopping and uninstalling

`ada stop` pauses the mind (the thinkers) and `ada start` resumes it. If
something is running away, `headlong-killall` stops every Headlong process on
the machine (dispatchers, thinker steps, shellm runs, the dashboard);
`headlong-killall --dry-run` shows what it would stop.

To see what Headlong has on a machine and what is running (read-only, works
even when nothing is on PATH):

```bash
curl -fsSL https://headlong.ai/status.sh | bash
```

To remove Headlong from the machine:

```bash
curl -fsSL https://headlong.ai/uninstall.sh | bash
```

(or `./uninstall.sh` / `./install.sh --uninstall` from a checkout). It shows
what is running and what it will remove, asks once, stops every Headlong
process, and deletes what the installer put in place. Your agent's
identities (memories, trajectory) are moved to
`~/headlong-identities-backup-<date>/` unless you say to delete them.
`--dry-run` shows the plan without changing anything; `--yes` skips the
prompts (for scripts); `uninstall.sh --help` lists the rest. If you
installed from your own clone with `./install.sh`, the clone and the
identities inside it are left alone.

By hand, the installer touches these places, and removing them uninstalls Headlong:

- `~/.headlong/` — the state home: `.env` (your API key), `status.json`,
  logs, and, for the one-liner, the checkout itself in `~/.headlong/app/`.
  Identities live inside the checkout at `<app>/.identities/`, so this is
  also where your agent's memories and trajectory are. Copy that directory
  first if you want to keep them.
- `~/.local/bin/` — one symlink (or copy) per tool, plus a symlink named
  after each identity (`ada`) that points at `persona`. `ls -l
  ~/.local/bin | grep -i headlong` finds them.
- `~/.skills/core-skills/` and `~/.headlong-thinkers/` — the bundled
  skills and thinker templates.
- A `PATH` line the installer offered to add to your shell rc file
  (`~/.zshrc` or `~/.bashrc`).

Run `headlong-killall` first so nothing is writing while you delete. For the
Docker variant, `docker rm -f headlong` removes the container and everything
in it.
