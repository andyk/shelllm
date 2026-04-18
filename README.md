```
           ______  _   _  _____ _______   __    __
___        |  ___|| | | ||  ___|| | | |  |  \  /  |
\   \      | |    | | | || |    | | | |  | \ \/ / |
  \   \    | |___ | |_| || |___ | | | |  | |\__/| |
    \   \  |___  ||  _  ||  ___|| | | |__| |    | |
    /   /      | || | | || |    | | |____|_|    |_|
  /   /     ___| || | | || |___ | |____|
/__ /      |_____||_| |_||_____||_____|
```

A bash-native AI agent that thinks by writing shell commands, running them, and iterating until it has an answer.

## Why the shell?

LLMs are text-in, text-out. The Unix shell is an environment where *everything* is text — stdin, stdout, pipes, files, environment variables. That structural alignment turns out to be deep.

Most agent frameworks give the LLM a curated menu of function calls: `search_web`, `read_file`, `run_sql`. If your menu doesn't include a capability, the model can't do it. The shell inverts this. Instead of enumerating tools, you drop the LLM into a composable environment and let it figure out what to do. `curl` is the HTTP client. `jq` is the JSON processor. `python3 -c` is the escape hatch. No schemas to define, no wrappers to write — the model composes tools the same way a human would, by piping them together.

shell<sup>LM</sup> takes this idea seriously. It's four small, composable tools — all pure bash — that together form a full agent stack. Each one does one thing well. They compose through the filesystem and environment variables, just like Unix intended.

| Tool | What it does |
|------|-------------|
| **shelllm** | The core loop — sends context to Claude, executes the bash it writes back, repeats |
| **shelly** | Interactive conversational agent with identity, memory, and skills |
| **mem** | CLI memory store — markdown files with YAML frontmatter, no database |
| **skills** | Skill manager — install, create, and use SKILL.md-based agent abilities |

shell<sup>LM</sup> is the engine at the center. The other three build on it to get from a stateless tool to a stateful agent — with memory, learned abilities, and persistent identity across sessions.

## Install

```bash
git clone https://github.com/andyk/shelllm.git
cd shelllm
./install.sh
```

This copies `shelllm`, `shelly`, `mem`, and `skills` to `/usr/local/bin`. Use `--symlinks` to symlink instead (edits take effect without reinstalling), or `--prefix ~/.local/bin` for a different location.

## Quick start

```bash
# Set your API key
export ANTHROPIC_API_KEY="sk-ant-..."

# Run it
shelllm what is the mass of jupiter in kilograms

# Pipe data in
cat dataset.csv | shelllm summarize this data and find outliers

# Pass files
shelllm -f paper.pdf -f notes.txt compare these documents

# Quotes are optional for inline context
shelllm research the latest advances in protein folding and write a summary
```

## How shell<sup>LM</sup> works

shell<sup>LM</sup> runs a loop:

1. Sends your context to Claude with a system prompt that says "write bash code"
2. Claude responds with a ` ```bash ` code block
3. shell<sup>LM</sup> executes the code (in Docker if available, locally otherwise)
4. Output streams back to Claude as the next message
5. Repeat until the code sets `FINAL="answer"` or hits max iterations

The LLM has full shell access. It can curl APIs, parse data with jq, write Python scripts, call itself recursively, install packages — whatever it takes to solve the task.

### What you see

shell<sup>LM</sup> streams everything live. Commands show in cyan, output in dim:

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

If a command hangs (waiting for interactive input), the inactivity watchdog kills it after `SHELLLM_INACTIVITY_TIMEOUT` seconds (default 30) and gives the LLM structured feedback on what went wrong.

### Completion signals

The LLM signals it has an answer by setting one of these in its bash code:

```bash
# Short answer
FINAL="The answer is 42"

# Long answer from a file
echo "detailed report..." > report.txt
FINAL_FILE=report.txt
```

shell<sup>LM</sup> captures the value and prints it to stdout. Everything else (progress, commands, debug) goes to stderr, so you can pipe the final answer:

```bash
shelllm -f data.csv compute the average > result.txt
```

### Context

There are three ways to pass context:

**Inline** — everything after the flags is your context (quotes optional):

```bash
shelllm explain why the sky is blue
shelllm "explain why the sky is blue"  # same thing
```

**Files** — use `-f` one or more times. Contents become `$FILE_CONTEXT1`, `$FILE_CONTEXT2`, etc:

```bash
shelllm -f data.json analyze this
shelllm -f chapter1.txt -f chapter2.txt compare these chapters
```

**Stdin** — piped data becomes `$CONTEXT`:

```bash
curl https://example.com | shelllm what is this page about
git diff | shelllm review this diff for bugs
```

These can be combined:

```bash
cat errors.log | shelllm -f config.yaml diagnose why the service is failing
```

### Nested calls

Code generated by shell<sup>LM</sup> can call shell<sup>LM</sup> itself:

**`shelllm "prompt"`** — starts a fresh nested run. The child gets its own conversation history and workspace. Good for independent subtasks:

```bash
# Inside generated code
category=$(shelllm "classify this text as positive/negative/neutral: $text")
```

**`shelllm --fork "prompt"`** — forks the current conversation history and workspace into a sub-loop. The child gets full context of what happened so far, plus its own copy of all workspace files:

```bash
# Inside generated code
result=$(shelllm --fork "now take the data we found and build a visualization")
```

`--fork` is useful when a subtask needs the parent's conversation context. For independent subtasks, plain `shelllm` is simpler and avoids the child re-interpreting the parent's instructions.

Nesting depth is capped by `--max-depth` (default 3) to prevent runaway costs. Sub-runs are stored inside the parent workspace under `.shelllm/sub-runs/`.

### Interactive command handling

Generated code runs with stdin connected to `/dev/null`. Interactive prompts (password dialogs, `[y/N]` confirmations, `read` commands) get immediate EOF instead of hanging.

If a process produces no output for `SHELLLM_INACTIVITY_TIMEOUT` seconds (default 30), the watchdog kills it and sends the LLM structured feedback:

```
Execution was KILLED after 30 seconds of inactivity
(likely waiting for interactive input that will never arrive).
stdin is connected to /dev/null.

DETECTED: Confirmation prompt. Retry with --yes, -y, --force,
--assume-yes, --non-interactive, or equivalent flag.
```

The LLM sees this and retries with non-interactive flags. For commands that truly need interaction, the LLM can use tmux to create a PTY session and interact with it step by step.

### Docker sandboxing

If Docker is running, shell<sup>LM</sup> automatically executes code inside a container. This means:

- The LLM can't accidentally modify your host system
- It can install packages (`apt-get install`) without affecting your machine
- The container comes with bash, python3, jq, curl, and tmux pre-installed
- Your workspace directory is mounted in, so files persist across iterations

```bash
# Auto-detected (default)
shelllm do something risky

# Force local execution
shelllm --no-docker do something risky

# Use a different base image
shelllm --docker-image python:3.12-slim write a flask app
```

Docker detection works like this:
- If Docker daemon is running and `--no-docker` isn't set → uses Docker
- If already inside a Docker container (e.g. CI) → runs locally (no nesting)
- If Docker isn't installed → runs locally

### Workspace

Each shell<sup>LM</sup> run gets a persistent workspace directory under `~/.shelllm/runs/<timestamp>_<slug>/`:

- All generated code executes in `$SHELLLM_WORKSPACE`
- Files created by the agent persist across iterations
- `.final` holds the completion answer
- `.messages.json` holds conversation history
- `.shelllm/sub-runs/` contains nested child runs

Workspaces persist after the run ends, so you can inspect results or resume later:

```bash
# Inspect a past run
ls ~/.shelllm/runs/

# Use a custom workspace directory instead
shelllm --workspace ./my-run research something complex
```

With Docker, the workspace is bind-mounted into the container at the same path, so files written inside the container appear on the host and vice versa.

### Session management

You can resume past sessions to continue where you left off:

```bash
# Resume the most recent session
shelllm --continue "now summarize what you found"

# Resume a specific session by name prefix
shelllm --start-from 2025-01-15 "try a different approach"
```

The resumed session picks up the full conversation history, so the LLM remembers everything from the previous run.

## From tool to agent: shelly, mem, and skills

shell<sup>LM</sup> is a powerful primitive, but it's stateless. Each run starts fresh — no memory of what happened last time, no learned abilities, no persistent identity. To get from a tool to an agent, you need memory, skills, and a way to tie them together across conversations.

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
mem search "user prefs"     # Semantic search (uses shelllm)

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

shelly ties it all together. It's an interactive conversational agent that wraps shell<sup>LM</sup>, mem, and skills into a stateful chat experience with session management.

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
| `--model` | `SHELLLM_MODEL` | `claude-opus-4-6` | Claude model to use |
| `--max-iterations` | `SHELLLM_MAX_ITERATIONS` | `25` | Max loop iterations before giving up |
| `--max-tokens` | `SHELLLM_MAX_TOKENS` | `16000` | Max tokens per API response |
| `--thinking-budget` | `SHELLLM_THINKING_BUDGET` | `10000` | Extended thinking token budget |
| `--max-depth` | `SHELLLM_MAX_DEPTH` | `3` | Max nesting depth for `--fork` and nested calls |
| — | `SHELLLM_INACTIVITY_TIMEOUT` | `30` | Seconds before killing idle execution |
| `--workspace DIR` | — | `~/.shelllm/runs/...` | Workspace directory |
| `--fork` | — | — | Fork current session into a sub-run (inside shelllm only) |
| `--continue` | — | — | Resume the most recent session |
| `--start-from NAME` | — | — | Resume a specific session (prefix match) |
| `--no-docker` | `SHELLLM_NO_DOCKER=1` | off | Disable Docker sandboxing |
| `--docker-image` | `SHELLLM_DOCKER_IMAGE` | `ubuntu:latest` | Docker image to use |
| `-f FILE` | — | — | Add file context (repeatable) |
| `-v, --verbose` | — | off | Show debug output |
| `-q, --quiet` | — | off | Suppress progress output, keep only final answer |

You can also put settings in a `.env` file in the working directory:

```bash
ANTHROPIC_API_KEY=sk-ant-...
SHELLLM_MODEL=claude-opus-4-7-20250715
SHELLLM_MAX_ITERATIONS=10
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
shelllm research the five most important ai launches from the last 7 days and summarize them in a markdown table with sources

# Travel planning from live web data
shelllm find the cheapest 3-night tokyo trips from san francisco in october and show the best date patterns and booking sources

# Vendor landscape research
shelllm compare the top open-source observability stacks for a 20-person saas startup and recommend one

# Competitor mapping
shelllm map the market for ai coding agents including pricing, key features, and the most notable launches this quarter

# Multi-source news synthesis
shelllm reconstruct a timeline of the latest major nvidia announcements from primary sources and reputable coverage

# Delegate subtasks to nested shelllm runs
shelllm research the ai coding agent market, split the work into data gathering and synthesis using nested shelllm calls, and write the final report to report.md
```

## Architecture

```
shelllm                      The execution engine
├── run_loop()               Core iteration: call Claude → extract code → execute → repeat
│   ├── call_claude()        Streaming API call with early code-block cutoff
│   ├── extract_code()       Pull first ```bash block from response
│   ├── execute_code()       Run in Docker or locally (stdin=/dev/null)
│   ├── watchdog             Background: kill on inactivity timeout
│   ├── poll_output          Foreground: stream new lines to stderr
│   └── check .final         Done? Return answer. No? Feed output back, loop.
├── detect_interactive_prompt()  Classify hung output (password, confirm, etc.)
├── build_inactivity_feedback()  Structured LLM guidance for non-interactive retry
├── run_forked_prompt()      Fork conversation + workspace into sub-run
└── Docker lifecycle         Auto-detect, setup, teardown

shelly                       Conversational agent
├── cmd_repl()               Interactive REPL with Ctrl+C support
├── cmd_send()               Send message → assemble context → call shelllm
├── assemble_context()       Personality + memories + skills → system prompt
├── Session management       new, switch, history, reset, compact
└── Passes MEM_DIR/SKILLS_DIR to shelllm environment

mem                          File-based memory store
├── add / forget / edit      CRUD on markdown files with YAML frontmatter
├── list / dump              Browse memories
└── search                   Semantic search via shelllm

skills                       Skill manager
├── list / search            Browse local + GitHub skills
├── install / remove         Manage installed skills
├── init                     Scaffold a new skill
└── show                     Print a skill's SKILL.md
```

All pure bash. No dependencies beyond bash, jq, and curl.

## Acknowledgements

shell<sup>LM</sup> is a port of [Recursive Language Models (RLM)](https://alexzhang13.github.io/blog/2025/rlm/) by Alex Zhang to bash, for bash.
