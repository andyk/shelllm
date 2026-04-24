```
███      █████ ██  ██ █████ ██ ██    ███   ███
  ███    ██    ██  ██ ██    ██ ██    ██ ███ ██
    ███  █████ ██▀▀██ ████  ██ ██    ██  █  ██
  ███       ██ ██  ██ ██    ██ █████ ██     ██    
███      █████ ██  ██ █████ ████████ 
```

A bash-native AI agent that thinks by writing shell commands, running them, and iterating until it has an answer. Composed of dead simple shell tools.

> For the full backstory and design philosophy, see [Philosophy and Introduction to shellm](philosophy.md).

## Why the shell?

LLMs are text-in, text-out. The Unix shell is an environment where *everything* is text — stdin, stdout, pipes, files, environment variables. That structural alignment turns out to be deep.

Most agent frameworks give the LLM a curated menu of function calls: `search_web`, `read_file`, `run_sql`. If your menu doesn't include a capability, the model can't do it. The shell inverts this. Instead of enumerating tools, you drop the LLM into a composable environment and let it figure out what to do. `curl` is the HTTP client. `jq` is the JSON processor. `python3 -c` is the escape hatch. No schemas to define, no wrappers to write — the model composes tools the same way a human would, by piping them together.

shellm takes this idea seriously. It's four small, composable tools — all pure bash — that together form a full agent stack. Each one does one thing well. They compose through the filesystem and environment variables, just like Unix intended.

| Tool | What it does |
|------|-------------|
| **shellm** | The core loop — sends context to Claude, executes the bash it writes back, repeats |
| **shellm-explore** | Visualize run trees and generate LLM-powered reports on what a run did and why |
| **shelly** | Interactive conversational agent with identity, memory, and skills |
| **mem** | CLI memory store — markdown files with YAML frontmatter, no database |
| **skills** | Skill manager — install, create, and use SKILL.md-based agent abilities |

shellm is the engine at the center. shellm-explore gives you visibility into what the engine did. The other three build on shellm to get from a stateless tool to a stateful agent — with memory, learned abilities, and persistent identity across sessions.

## Install

```bash
git clone https://github.com/andyk/shellm.git
cd shellm
./install.sh
```

This copies `shellm`, `shellm-explore`, `shelly`, `mem`, and `skills` to `/usr/local/bin`. Use `--symlinks` to symlink instead (edits take effect without reinstalling), or `--prefix ~/.local/bin` for a different location.

## Quick start

```bash
# Set your API key
export ANTHROPIC_API_KEY="sk-ant-..."

# Run it
shellm what is the mass of jupiter in kilograms

# Pipe data in
cat dataset.csv | shellm summarize this data and find outliers

# Pass files
shellm -f paper.pdf -f notes.txt compare these documents

# Quotes are optional for inline context
shellm research the latest advances in protein folding and write a summary
```

## How shellm works

shellm runs a loop:

1. Sends your context to Claude with a system prompt that says "write bash code"
2. Claude responds with a ` ```bash ` code block
3. shellm executes the code (in Docker if available, locally otherwise)
4. Output streams back to Claude as the next message
5. Repeat until the code sets `FINAL="answer"` or hits max iterations

The LLM has full shell access. It can curl APIs, parse data with jq, write Python scripts, call itself recursively, install packages — whatever it takes to solve the task.

### What you see

shellm streams everything live. Commands show in cyan, output in dim:

```
▶ Iteration 1/25 — calling Claude API...
▶ Executing bash (12 lines):
    curl -s "https://api.example.com/data" | jq '.results'
    ...
  $ curl -s 'https://api.example.com/data'
  $ jq '.results'
  │ {"count": 42, "items": [...]}
  $ FINAL="Found 42 results"
  Exit 0

▶ Final answer received
Found 42 results
```

If a command hangs (waiting for interactive input), the inactivity watchdog kills it after `SHELLM_INACTIVITY_TIMEOUT` seconds (default 30) and gives the LLM structured feedback on what went wrong.

### Completion signals

The LLM signals it has an answer by setting one of these in its bash code:

```bash
# Short answer
FINAL="The answer is 42"

# Long answer from a file
echo "detailed report..." > report.txt
FINAL_FILE=report.txt
```

shellm captures the value and prints it to stdout. Everything else (progress, commands, debug) goes to stderr, so you can pipe the final answer:

```bash
shellm -f data.csv compute the average > result.txt
```

### Context

There are three ways to pass context:

**Inline** — everything after the flags is your context (quotes optional):

```bash
shellm explain why the sky is blue
shellm "explain why the sky is blue"  # same thing
```

**Files** — use `-f` one or more times. Contents become `$FILE_CONTEXT1`, `$FILE_CONTEXT2`, etc:

```bash
shellm -f data.json analyze this
shellm -f chapter1.txt -f chapter2.txt compare these chapters
```

**Stdin** — piped data becomes `$CONTEXT`:

```bash
curl https://example.com | shellm what is this page about
git diff | shellm review this diff for bugs
```

These can be combined:

```bash
cat errors.log | shellm -f config.yaml diagnose why the service is failing
```

### Nested calls

Code generated by shellm can call shellm itself:

**`shellm "prompt"`** — starts a fresh nested run. The child gets its own conversation history and env. Good for independent subtasks:

```bash
# Inside generated code
category=$(shellm "classify this text as positive/negative/neutral: $text")
```

Nesting depth is capped by `--max-depth` (default 5) to prevent runaway costs. Sub-runs are stored inside the parent workdir under `.shellm/sub-runs/`.

### Interactive command handling

Generated code runs with stdin connected to `/dev/null`. Interactive prompts (password dialogs, `[y/N]` confirmations, `read` commands) get immediate EOF instead of hanging.

If a process produces no output for `SHELLM_INACTIVITY_TIMEOUT` seconds (default 30), the watchdog kills it and sends the LLM structured feedback:

```
Execution was KILLED after 30 seconds of inactivity
(likely waiting for interactive input that will never arrive).
stdin is connected to /dev/null.

DETECTED: Confirmation prompt. Retry with --yes, -y, --force,
--assume-yes, --non-interactive, or equivalent flag.
```

The LLM sees this and retries with non-interactive flags. For commands that truly need interaction, the LLM can use tmux to create a PTY session and interact with it step by step.

### Docker sandboxing

If Docker is running, shellm automatically executes code inside a container. This means:

- The LLM can't accidentally modify your host system
- It can install packages (`apt-get install`) without affecting your machine
- The container comes with bash, python3, jq, curl, and tmux pre-installed
- Your workdir is mounted in, so files persist across iterations

```bash
# Auto-detected (default)
shellm do something risky

# Force local execution (use the "local" env)
shellm --env local do something risky

# Use a different base image
shellm --docker-image python:3.12-slim write a flask app

# Teardown container on exit instead of persisting
shellm --temp-docker do something risky
```

Docker detection works like this:
- If Docker daemon is running and env isn't `local` → uses Docker
- If already inside a Docker container (e.g. CI) → runs locally (no nesting)
- If Docker isn't installed → runs locally

### Envs

An **env** is a named execution environment — either a Docker container or "local" (the host machine). Multiple runs can share an env, so installed packages and system modifications persist across conversations.

Each run also has a **workdir** — a file directory under `~/.shellm/runs/<timestamp>_<slug>/`:

- All generated code executes in `$SHELLM_WORKDIR`
- Files created by the agent persist across iterations
- `final` holds the completion answer
- `history.json` holds conversation history
- `.shellm/sub-runs/` contains nested child runs

Env metadata is stored in `~/.shellm/envs/<name>/`.

```bash
# Inspect past runs
ls ~/.shellm/runs/

# Use a custom workdir
shellm --workdir ./my-run research something complex

# Use a named env (Docker container persists between runs)
shellm --env my-project do something
shellm --env my-project do something else  # reuses container

# Run on host (no Docker)
shellm --env local do something

# Teardown container on exit
shellm --temp-docker do something risky
```

With Docker, the workdir is bind-mounted into the container at the same path, so files written inside the container appear on the host and vice versa.

### Context summary

At the start of every run, shellm kicks off a background process that generates a `context.md` file summarizing what the run is about. This calls a fast model (configurable via `SHELLM_SUMMARY_MODEL`, defaults to Haiku) with all the input context — CLI arguments, stdin, and file contents — and produces:

- **TLDR** — a one-line summary of the run's context and goal
- **Full Summary** — a multi-paragraph summary (only for large inputs)
- **Context Provided** — the raw CLI text, stdin preview, and each file as a `##` subheader with an LLM-generated description and the first 500 characters

This runs asynchronously and doesn't slow down the main loop. The generated `context.md` lives at `$rundir/.shellm/context.md` and is used by `shellm-explore` to label runs in tree visualizations.

### Exploring runs with shellm-explore

`shellm-explore` visualizes the tree of runs and sub-runs that shellm creates. When shellm delegates subtasks via nested calls, you get a hierarchy of run directories. `shellm-explore` walks that tree and displays it with TLDR summaries from each run's `context.md`.

```bash
# Show the run tree for a given run
shellm-explore ~/.shellm/runs/2026-04-23-10-30-00_abc123_research-ai

# Generate an LLM-powered report explaining the run tree
shellm-explore ~/.shellm/runs/2026-04-23-10-30-00_abc123_research-ai --report
```

Tree output highlights the target run and shows parent/child relationships:

```
2026-04-23-10-30-00_abc123_research-ai: Research the AI coding agent market and write a report
  2026-04-23-10-31-12_def456_gather...: Gather pricing and feature data for top AI coding agents
  2026-04-23-10-32-45_ghi789_synthe...: >>> Synthesize findings into a comparative report <<<
```

With `--report`, it sends the full tree context to an LLM and generates an analysis of what the run tree accomplished, why each sub-run exists, and how they relate to each other.

## From tool to agent: shelly, mem, and skills

shellm is a powerful primitive, but it's stateless. Each run starts fresh — no memory of what happened last time, no learned abilities, no persistent identity. To get from a tool to an agent, you need memory, skills, and a way to tie them together across conversations.

### mem

A file-based memory store. Each memory is a markdown file with YAML frontmatter (date, type, slug). No database needed.

```bash
# Add memories with a type
mem add "the user prefers dark mode"
mem add --type todo "buy groceries"
mem add --type value "always be honest"
mem add --type fact "the project uses React 19"

# Search and browse
mem list                    # List all (date + slug)
mem dump                    # Print all summaries
mem search "user prefs"     # Semantic search (uses shellm)

# Edit and remove
mem edit <name> "new text"  # Update a memory
mem forget <name>           # Delete by name or prefix
```

Types: `memory`, `todo`, `objective`, `value`, `belief`, `fact`, `preference`, `note`

Memories are stored as individual `.md` files in `MEM_DIR` (default: `./.memories/`). Every piece of state is a text file — inspectable, greppable, editable with any editor.

### skills

A manager for SKILL.md-based agent abilities. Skills are directories containing a `SKILL.md` file with YAML frontmatter (name, description) and markdown instructions. They're reusable instruction sets that encode how to do specific things well — no plugin API, no SDK, just text files the LLM reads and follows.

```bash
# List installed skills
skills

# Search installed and remote (GitHub) skills
skills "web research"

# Install from GitHub
skills --install owner/repo

# Show a skill's full instructions
skills --show web-research

# Create a new skill
skills --init my-new-skill

# Remove a skill
skills --remove old-skill
```

Skills live in `SKILLS_DIR` (default: `~/.skills/`). shelly also has per-session skills in `.shelly/sessions/<id>/skills/`.

### shelly

shelly ties it all together. It's an interactive conversational agent that wraps shellm, mem, and skills into a stateful chat experience with session management.

```bash
# Start the REPL
shelly

# Or send a single message
shelly send "what's the weather in SF?"

# Send with piped input
cat report.csv | shelly send "summarize this report"
```

#### REPL

```
shelly repl (Ctrl+C to interrupt, Ctrl+D to exit)
> hello! who are you?
I'm shelly, an AI with a life context — memories, values, skills...
> /help
```

Ctrl+C interrupts a running response and returns to the prompt. Ctrl+D exits.

#### Sessions

shelly keeps conversation history per session:

```bash
shelly new              # Start a new session
shelly sessions         # List all sessions
shelly switch <id>      # Switch to a session (prefix match)
shelly history          # Show conversation history
shelly reset            # Clear current session
shelly compact          # Summarize and compact long history
```

#### Slash commands (in REPL)

| Command | Description |
|---------|-------------|
| `/new` | Start a new session |
| `/sessions` | List sessions |
| `/switch <id>` | Switch session |
| `/history` | Show history |
| `/reset` | Clear session |
| `/compact` | Compact history |
| `/context` | Show assembled system prompt |
| `/mem ...` | Memory commands (see above) |
| `/skills ...` | Skills commands (see above) |
| `/quit` | Exit |

## Options

All configuration is available as both CLI flags and environment variables. Flags take precedence.

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--model` | `SHELLM_MODEL` | `claude-opus-4-6` | Claude model to use |
| `--max-iterations` | `SHELLM_MAX_ITERATIONS` | `25` | Max loop iterations before giving up |
| `--max-tokens` | `SHELLM_MAX_TOKENS` | `16000` | Max tokens per API response |
| `--thinking-budget` | `SHELLM_THINKING_BUDGET` | `10000` | Extended thinking token budget |
| `--max-depth` | `SHELLM_MAX_DEPTH` | `5` | Max nesting depth for nested shellm calls |
| — | `SHELLM_INACTIVITY_TIMEOUT` | `30` | Seconds before killing idle execution |
| `--workdir DIR` | — | `~/.shellm/runs/...` | Working directory for the run |
| `--env NAME` | `SHELLM_ENV` | auto-generated | Named execution environment (Docker container or `local`) |
| `--temp-docker` | `SHELLM_TEMP_DOCKER=1` | off | Teardown Docker container on exit |
| `--docker-image` | `SHELLM_DOCKER_IMAGE` | `ubuntu:latest` | Docker image to use |
| `-f FILE` | — | — | Add file context (repeatable) |
| `-v, --verbose` | — | off | Show debug output |
| `-q, --quiet` | — | off | Suppress progress output, keep only final answer |

You can also put settings in a `.env` file in the working directory:

```bash
ANTHROPIC_API_KEY=sk-ant-...
SHELLM_MODEL=claude-opus-4-7-20250715
SHELLM_MAX_ITERATIONS=10
```

## Prerequisites

**Required:**
- bash (3.2+)
- jq
- curl

**Optional:**
- Docker — for sandboxed execution (auto-detected)
- python3 — for some generated code
- lynx — for web scraping tasks

## Examples

```bash
# Weekly research brief
shellm research the five most important ai launches from the last 7 days and summarize them in a markdown table with sources

# Travel planning from live web data
shellm find the cheapest 3-night tokyo trips from san francisco in october and show the best date patterns and booking sources

# Vendor landscape research
shellm compare the top open-source observability stacks for a 20-person saas startup and recommend one

# Competitor mapping
shellm map the market for ai coding agents including pricing, key features, and the most notable launches this quarter

# Multi-source news synthesis
shellm reconstruct a timeline of the latest major nvidia announcements from primary sources and reputable coverage

# Delegate subtasks to nested shellm runs
shellm research the ai coding agent market, split the work into data gathering and synthesis using nested shellm calls, and write the final report to report.md
```

## Architecture

```
shellm                      The execution engine
├── run_loop()               Core iteration: call Claude → extract code → execute → repeat
│   ├── call_claude()        Streaming API call with early code-block cutoff
│   ├── extract_code()       Pull first ```bash block from response
│   ├── execute_code()       Run in Docker or locally (stdin=/dev/null)
│   ├── watchdog             Background: kill on inactivity timeout
│   ├── poll_output          Foreground: stream new lines to stderr
│   ├── generate_context_md  Background: async context summary via fast model
│   └── check .final         Done? Return answer. No? Feed output back, loop.
├── detect_interactive_prompt()  Classify hung output (password, confirm, etc.)
├── build_inactivity_feedback()  Structured LLM guidance for non-interactive retry
└── Docker lifecycle         Auto-detect, setup, teardown

shellm-explore              Run tree visualization & analysis
├── print_tree()             Walk run hierarchy, display with TLDR summaries
├── generate_report()        LLM-powered analysis of run tree structure
└── get_summary()            Read TLDR from context.md (or fallback to command)

shelly                       Conversational agent
├── cmd_repl()               Interactive REPL with Ctrl+C support
├── cmd_send()               Send message → assemble context → call shellm
├── assemble_context()       Personality + memories + skills → system prompt
├── Session management       new, switch, history, reset, compact
└── Passes MEM_DIR/SKILLS_DIR to shellm environment

mem                          File-based memory store
├── add / forget / edit      CRUD on markdown files with YAML frontmatter
├── list / dump              Browse memories
└── search                   Semantic search via shellm

skills                       Skill manager
├── list / search            Browse local + GitHub skills
├── install / remove         Manage installed skills
├── init                     Scaffold a new skill
└── show                     Print a skill's SKILL.md
```

All pure bash. No dependencies beyond bash, jq, and curl. Five tools, each a single file.

## Acknowledgements

shellm is a port of [Recursive Language Models (RLM)](https://alexzhang13.github.io/blog/2025/rlm/) by Alex Zhang to bash, for bash.
