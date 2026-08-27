---
name: shellm
description: Reference for the shellm system — recursive LLM shell, identity management, memory, skills, trajectory, and all CLI tools. Use when working on shellm itself, debugging agent behavior, or understanding how the pieces fit together.
---

# shellm

> **This skill may be out of date.** The source of truth is always the code in `bin/`. If you find discrepancies, use the `skill-author` skill to update this file and open a PR.

## Architecture overview

shellm is a set of composable bash scripts that turn an LLM into an autonomous agent living in a shell. The stack, bottom to top:

```
llm              raw LLM calls (Anthropic, OpenAI, Gemini, Bedrock, and more)
shellm           recursive execute-in-shell loop on top of llm
traj / context   step log (DAG) + message assembly for multi-turn
mem / skills     persistent memory + learnable capabilities
identity         isolated agent identities (own mem, skills, traj)
think / chat     autonomous thinking + human conversation
focus            goal tracking
```

An agent activates an identity (`source .identities/<name>/activate`), which sets env vars. All tools read from those env vars — no global config files.

## bin/ reference

### Core engine

| Script | Purpose |
|--------|---------|
| `shellm` | Recursive LLM-in-bash loop. Sends a prompt to the LLM, executes returned bash code blocks, feeds output back, repeats until `FINAL` is set. The heart of the system. |
| `llm` | Multi-provider LLM CLI. `llm [options] prompt` or stdin. Supports Anthropic, OpenAI, Gemini, OpenRouter, OpenCode, and Amazon Bedrock. Key flags: `-m MODEL`, `-s SYSTEM`, `-M MESSAGES_JSON`, `--stream`, `--thinking`. |

### Identity & activation

| Script | Purpose |
|--------|---------|
| `identity` | Manage isolated identities. Each has its own memories, skills, kernel, traj. Subcommands: `new`, `list`, `info`, `switch`, `delete`, `shell`, `prompt`. |

Activate an identity to set env vars for all other tools:
```bash
source .identities/myagent/activate   # activate in current shell
deactivate_identity                    # undo
identity shell myagent                 # or: start a subshell
```

### Thinking & conversation

| Script | Purpose |
|--------|---------|
| `think` | One autonomous think cycle. Reads traj + memories, calls shellm with think prompt, writes thought/action to traj, dispatches thought processes. `think step [--dry-run]`. |
| `chat` | Send messages into the thought stream. `chat send <msg>` appends a human-msg step. `chat repl` gives a readline loop. |
| `focus` | Goal management. `focus set <goal>`, `focus show`, `focus done <query>`. Stores goals as mem entries with type=goal. |

### Memory & skills

| Script | Purpose |
|--------|---------|
| `mem` | File-based memory store (markdown + YAML frontmatter). `mem add --type TYPE <text>`, `mem search <query>`, `mem list`, `mem show <name>`, `mem forget <name>`, `mem edit <name> <text>`. |
| `skills` | Skill management. `skills install <src>`, `skills show <name>`, `skills promote <name>` (to kernel), `skills search <query>`, `skills remote add <path>`. |

### Trajectory & context

| Script | Purpose |
|--------|---------|
| `traj` | Trajectory operations (single-file and tree). Uses `TRAJ_DIR` + `TRAJ_ID`. `traj new`, `traj append`, `traj tail`, `traj cat`, `traj fork`, `traj merge`, `traj show`, `traj list`, `traj root`. `show` is unified: pass any ID (trajectory or step) and it searches all files in traj_dir. |
| `context` | Reads traj, outputs a JSON messages array for `llm -M`. Maps step types to assistant/user roles. Key flags: `--traj_dir`, `--tail N`, `--head N`, `--max-bytes`, `--pin <step_id>`. |

### File utilities

| Script | Purpose |
|--------|---------|
| `view` | Read files with line numbers. `view FILE [START[:END]]`. |
| `glob` | Git-aware glob matching sorted by mtime. `glob PATTERN [DIR] [--limit N]`. |
| `sub` | Exact-string substitution in files. `sub FILE OLD NEW [--replace-all]`. |
| `put` | Atomic file write from stdin. `echo content \| put FILE [--force]`. |

### Docker sandboxing

| Script | Purpose |
|--------|---------|
| `shellm-docker` | Constrained Docker facade for sandboxed execution. `run`, `build`, `ps`, `logs`, `rm`. |
| `shellm-docker-broker` | Host-side broker that manages Docker containers for sandboxed shellm envs. |
| `shellm-explore` | (Not covered here — run exploration tool.) |

## Key environment variables

These are set by `source .identities/<name>/activate`:

| Variable | Points to |
|----------|-----------|
| `IDENTITY_NAME` | Identity name (e.g. "andy") |
| `IDENTITY_DIR` | Identity root dir (e.g. `.identities/andy`) |
| `MEM_DIR` | `$IDENTITY_DIR/memories` |
| `SKILLS_DIR` | `$IDENTITY_DIR/skills` |
| `SKILLS_KERNEL_DIR` | `$IDENTITY_DIR/kernel` |
| `TRAJ_DIR` | `$IDENTITY_DIR/trajectories` |
| `TRAJ_ID` | UUID of root trajectory |
| `SHELLM_TRAJ_DIR` | Trajectory directory (default `$HOME/.shellm/trajectories`) |
| `SHELLM_ENVS_DIR` | Env/container state directory |
| `SHELLM_WORKDIRS_DIR` | Working directories base |
| `SHELLM_BROKER_DIR` | Docker broker state directory |
| `THINK_MODEL` | Model for think cycles |
| `THINK_TICK_INTERVAL` | Seconds between autonomous ticks |

Other important vars (not identity-scoped):

| Variable | Purpose |
|----------|---------|
| `SHELLM_MODEL` | Default model for shellm |
| `ANTHROPIC_API_KEY` | Anthropic API key for llm |
| `OPENAI_API_KEY` | OpenAI API key for llm |

## Identity directory layout

```
.identities/<name>/
  info.txt              name=, cwd=, created=, think_model=, interval=
  activate              source-able activation script
  core_identity_prompt.md  (optional) custom system prompt
  .env                  (optional) identity-specific env vars
  memories/             mem entries (markdown files)
  skills/               installed skills
    .skillsrc           skill remotes config
  kernel/               kernel skills (always loaded)
    mem/SKILL.md        bootstrapped mem skill
  .trajectories/        trajectory files
    trajectory.jsonl          main consciousness stream
    blobs/              spilled large fields
  .shellm/              shellm working state
  workdir/              working directory for think cycles
```

## How a think cycle works

1. `think step` loads the think prompt template from `$IDENTITY_DIR/prompts/think.md`
2. Replaces `{{identity_name}}` and `{{goals}}` in the template
3. Appends recent traj context (last N steps via `traj tail`)
4. Calls `shellm` with this prompt — shellm executes bash, loops until FINAL
5. Writes the resulting thought or action to traj
6. If it was an action, forks a child branch, executes via shellm, merges back
7. Dispatches thought processes (TPs) — each TP gets recent thoughts and can write to traj/mem

## Thinkers

Thinkers live in `thinkers/`. Each has a `step` script, `prompt.md`, and `subscriptions.jsonl`. They subscribe to trajectory events and run autonomously via `thinkers start`:

- **main** — core thought generator, produces stream-of-consciousness thoughts and actions
- **intentions-goals-creator** — notices emerging goals, stores via mem
- **intentions-goals-enforcer** — redirects when the stream drifts from goals
- **learning** — extracts lessons from action/observation pairs
- **mind-wandering** — surfaces associative memories
- **system-architecture** — meta-cognitive self-modification
- **values-beliefs-creator** — crystallizes values and beliefs
- **values-beliefs-enforcer** — flags misalignment between behavior and values

## Tips

- All tools are designed to be composed via pipes and env vars
- `shellm` is the only script that calls the LLM directly (via `llm`); everything else builds prompts and calls `shellm`
- The `context` script is the bridge between traj (step log) and llm (messages array)
- Skills are loaded on-demand via `skills show <name>`; kernel skills are always in context
- To understand any script's full interface, run it with `--help` or read the source in `bin/`
