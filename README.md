```
██  ██ █████  ████  █████  ██     ████  ██  ██  ████               ██
██  ██ ██    ██  ██ ██  ██ ██    ██  ██ ███ ██ ██           ██   ██
██▀▀██ ████  ██████ ██  ██ ██    ██  ██ ██▀███ ██ ███     ██   ██
██  ██ ██    ██  ██ ██  ██ ██    ██  ██ ██ ▀██ ██  ██   ██   ██
██  ██ █████ ██  ██ █████  █████  ████  ██  ██  █████      ██
```

[![CI](https://github.com/laude-institute/headlong/actions/workflows/ci.yml/badge.svg)](https://github.com/laude-institute/headlong/actions/workflows/ci.yml)

**Headlong** is an open source agent microharness, a complete agent harness
with a core of about 12K lines of Bash.

[Launch post](https://www.laude.org/updates/headlong-a-microharness-for-persistent-agents) |
[Announcement](https://x.com/andykonwinski/status/2091990178638496195)

> [!IMPORTANT]
> Headlong is alpha research software. Expect frequent changes. Run it in a
> sandbox because Headlong agents run shell commands. Use a dedicated,
> spend-capped API key, and do not give your agent sensitive secrets.

Headlong's defining feature is **persistent
agency**. Your agent keeps thinking between external interactions in a
self-guided loop inspired by human inner monologue. A message from a human
doesn't start a session. It lands in the agent's thought stream as one more
observation, and the agent decides if and when to respond. You give your agent
a name and a personality, and it sets its own interests and priorities, starts
its own projects, and pings you when it has something to say.

A Headlong agent is also built to be shared. A whole team can talk to one
agent over Slack, Telegram, and a chat app, and every conversation lands
in the agent's single stream of thoughts. The agent follows what different
people are working on, connects them, and pings whoever seems most
relevant. Sharing one agent is fun, because it behaves more like a person
than a service.

At the heart of Headlong is `shellm`, a Bash implementation of a
[recursive language model (RLM)](https://alexzhang13.github.io/blog/2025/rlm/).
The agent thinks by writing shell commands, running them, and reading the
output. No tool system besides Bash is needed.

## Get started

One line installs everything, interviews you to bring a Headlong agent to
life, and opens a dashboard where you can watch its mind run:

```bash
curl -fsSL https://headlong.ai/install.sh | bash
```

You'll need bash 3.2+, git, curl, jq, Python 3, and an LLM API key (Anthropic,
OpenAI, Gemini, or OpenRouter) — or a local model on any
OpenAI-compatible server (llama.cpp, Ollama, vLLM, LM Studio; see
[Local models](#local-models) below, no key needed); the dashboard also
needs [uv](https://docs.astral.sh/uv/) and bun or node, and the installer
offers to fetch those.

Headlong is alpha research software. Use a dedicated, spend-capped key, because
your agent runs real shell commands and thinks around the clock. With Docker
running, the installer offers to keep the whole agent in a container, or to
install on your machine with the agent's commands sandboxed in a container
(an unsandboxed host install exists too, behind an explicit yes, and is not
recommended).
Without Docker the commands would run directly on your machine as you, so the
installer stops and asks for an explicit yes before setting that up. How much
the background thinking costs depends on how quickly
the agent loops and which model backs it. The rate of thinking backs off
exponentially when nobody is talking to the agent and resets the moment a
message arrives.  At the settings we run our agent with, it comes to $1 to $2
an hour.

The agent's name becomes a command:

```bash
ada hello            # one message, wait for the reply
ada                  # chat
ada stop / ada start # pause / resume its mind
ada dash             # open the dashboard
ada bugreport        # bundle logs + trajectory (keys scrubbed) for a bug report
```

`headlong-killall` stops every Headlong process on the machine if you need a
panic button. `curl -fsSL https://headlong.ai/status.sh | bash` shows what is
installed and running; `curl -fsSL https://headlong.ai/uninstall.sh | bash`
removes it all (details in
[docs/install.md](docs/install.md#stopping-and-uninstalling)).

The container flow the installer offers is this, and you can also run it
yourself:

```bash
docker run -it --name headlong --restart unless-stopped -p 8080:8080 \
  --add-host host.docker.internal:host-gateway buildpack-deps:curl \
  bash -c 'curl -fsSL https://headlong.ai/install.sh | bash; exec bash'
```

Details, non-interactive/CI installs, and installing from a checkout are
in [docs/install.md](docs/install.md).

## Key ideas

- **Persistent agency.** Most harnesses are reactive, or wake on a
  schedule to run a fixed checklist. A Headlong agent is never asleep and
  there is no checklist. It keeps generating thoughts about whatever it
  decides is interesting, even when there is no external input. Messages
  from Slack, Telegram, or the chat app are injected into the thought
  stream as observations, and the agent decides if and when to respond.
  Classic turn-taking request/response mode works too.
- **Multi-player fun.** One agent, one mind, many people. There are no
  per-user sessions; the agent experiences all of its conversations in a
  single timeline and decides who to reply to and when. That single
  stream also means no hard walls between people: assume anything you
  tell the agent is shared with everyone who talks to it.
- **Built around Ken Thompson's philosophy.** The core tooling is a
  handful of small Bash executables (`shellm`, `traj`, `llm`, `responses`,
  `context`, `mem`, `skills`, ...), each doing one thing well and composing through
  pipes, files, and environment variables. The model writes shell
  commands, so `curl` is the HTTP client and `jq` is the JSON processor.
- **An agent's trajectory is a DAG of jsonl files** with fork and merge.
  An agent has access to everything it has thought and done, and the
  tooling to explore it down to any single step.
- **Context is a projection of the trajectory.** Nothing is compacted
  away in place. Compaction and agent introspection operate on the same
  files with the same tools.
- **Tiered context compaction.** The entire trajectory stays in context
  at exponentially decaying resolution. Recent entries appear verbatim,
  and older entries are progressively summarized. The tiers act as an
  index, so the agent can retrieve raw entries when it needs them.
- **Subagents see their ancestors' trajectories.** A subagent can see why
  it was created, what the parent already tried, and how it fits into the
  big picture.
- **Docker by default.** Generated code sandboxes itself into a container
  whenever Docker is available, and container reuse keeps restarts cheap.
  Local mode works too.
- **Self-improvement by fork, test, merge.** An agent forks the Headlong
  codebase (and optionally its own trajectory), changes something, and
  runs. Merge the change back if it worked, or discard the agent and its
  changes if it didn't. No rollback machinery is needed. The agent we run
  at Laude works in its own fork of this repo, and we have pulled over 50
  of its commits back into main.

The full backstory and design philosophy are in
[philosophy.md](philosophy.md).

## The tools

To make a minimal agent, you need:

- a loop that repeatedly generates the next thought (`thinkers`, which
  calls `llm`),
- a way for a thought to reason and act (`shellm`, with Bash as the only
  tool),
- a way to record the agent's trajectory, its life so far (`traj`), and
- a way to turn that trajectory into the context for the next call into
  the LLM (`context`).

Headlong also gives an agent a few convenience tools, such as a way to
distill and codify its experience (`mem`) and a way to save and reuse
procedures for specialized tasks (`skills`). The core is the tools the
running mind executes, the executables in `bin/` plus the thought
processes in `thinkers/`, and it comes to about 11.9K lines by cloc's count (capped at 12K). A
harness this small can be read end to end, and it is easy to modify and
experiment with.

| Tool | What it does |
|------|-------------|
| **shellm** | The RLM core. It sends context to an LLM, runs the bash the LLM writes back, and repeats |
| **llm** | Multi-provider LLM CLI. Anthropic, OpenAI, Gemini, OpenRouter, and any local OpenAI-compatible server (llama.cpp, Ollama, vLLM, ...) behind one interface |
| **traj** | Trajectory operations on append-only jsonl DAGs with fork and merge |
| **context** | Renders a trajectory into an LLM messages array with tiered compaction |
| **thinkers** | The mind. Reactive thought processes run by a dispatcher |
| **chat** / **focus** | Messages and goals on an identity's trajectory |
| **mem** / **skills** | File-based memory store and SKILL.md-based abilities |
| **recap** | Summarizes a trajectory into themes and episodes |
| **shellm-docker** | Constrained docker facade staged into sandbox containers for generated code |
| **glob** / **view** / **put** / **sub** | Small file tools the agent uses instead of the sharp edges of coreutils |

Everything you run *around* the mind lives in `tools/`:

| Tool | What it does |
|------|-------------|
| **shellm-docker-broker** | Host-side policy server for brokered Docker, never present in the mind's environment |
| **identity** | Creates and manages identities (persona, memories, activate script) |
| **persona** | Talks to and manages an identity by name, from anywhere |
| **headlong-init** | One-time bootstrap: interview, first identity, first thoughts |
| **shellm-explore** | Visualizes run trees and writes LLM-powered reports on what happened and why |
| **headlong-web** | The dashboard, where you watch a mind think in the browser |
| **headlong-slack-bridge** / **headlong-telegram-bridge** | Slack and Telegram connectors into the same inner experience |
| **headlong-killall** | Panic button that stops every Headlong-related process |
| **pr-committee** | Multi-model pull request review, used on this repo |

## Local models

Headlong can use any server that supports the OpenAI chat completions API,
including llama.cpp, Ollama, vLLM, and LM Studio. A local server does not
need an API key unless you configured the server to require one.

For llama.cpp, start the server with an alias that Headlong can use as the
model name:

```bash
llama-server \
  -m qwen3-8b-instruct.gguf \
  --alias qwen3-8b-instruct \
  -c 32768
```

Then check the connection:

```bash
LLM_PROVIDER=openai-compatible \
LLM_API_URL=http://127.0.0.1:8080/v1/chat/completions \
llm -m qwen3-8b-instruct "hello"
```

For Ollama, start the server if it is not already running:

```bash
ollama serve
```

With the server running, download a model and check the connection:

```bash
ollama pull qwen3:8b
LLM_PROVIDER=openai-compatible \
LLM_API_URL=http://127.0.0.1:11434/v1/chat/completions \
llm -m qwen3:8b "hello"
```

To configure an existing Headlong agent without running the installer again,
add the provider, server address, and model to `~/.headlong/.env`:

```bash
LLM_PROVIDER='openai-compatible'
SHELLM_API_URL='http://127.0.0.1:11434/v1/chat/completions'
SHELLM_MODEL='qwen3:8b'
```

The example uses Ollama. For the llama.cpp example above, use port 8080 and
the `qwen3-8b-instruct` model alias instead. If the server requires a bearer
token, add `LLM_API_KEY` to the same file.

Restart the agent after changing an existing configuration. Replace `ada`
with your agent's name:

```bash
ada stop
ada start
```

To let the installer write the same settings, run it and choose the local
model server when asked:

```bash
curl -fsSL https://headlong.ai/install.sh | bash
```

A local server can also be selected without a terminal:

```bash
export HEADLONG_PROVIDER=local
export HEADLONG_LOCAL_URL=http://127.0.0.1:11434/v1
export HEADLONG_LOCAL_MODEL=qwen3:8b
curl -fsSL https://headlong.ai/install.sh | bash
```

For a host installation, keep a local server address such as `127.0.0.1`
or `localhost`. Headlong changes the address only when `shellm` runs code
inside its Docker sandbox. A full Headlong container uses
`host.docker.internal` to reach a server on the Docker host.

On Linux, the model server must listen on an address that Docker can reach.
For example, llama.cpp can use `--host 0.0.0.0`, and Ollama can use
`OLLAMA_HOST=0.0.0.0:11434`. Use the machine firewall to keep the model
server off untrusted networks.

Be aware that `host.docker.internal` gives agent code access to other
services running on the host. Do not rely on loopback binding alone to
protect a sensitive service when this route is enabled. See
[the installation guide](docs/install.md#the-one-liner) for the full
networking and security details.

For direct `llm` configuration, thinking options, and provider behavior,
see [the shellm guide](docs/shellm.md#the-llm-tool). The provider policy is
in [design/providers.md](design/providers.md).

## Learn more

- [Operating Headlong](docs/operating-headlong.md) — choose a runtime and
  operate identities, thinkers, chat, memory, trajectories, and skills safely
- [Using Responses](docs/responses-guide.md) — completion workers, background
  recovery, resumable sessions, WebSocket transport, compaction, and examples
- [Agent operating skills](skills/README.md) — procedural guidance for core
  Headlong and Responses, installed with the framework and discoverable by
  coding agents in this checkout
- [philosophy.md](philosophy.md) — the case for applying Ken Thompson's
  philosophy to agent microharnesses, and the full design story
- [docs/shellm.md](docs/shellm.md) — the shellm engine reference: the
  loop, context passing, Docker sandboxing, envs, the `llm` tool, options
- [docs/install.md](docs/install.md) — every install variant, including
  CI/non-interactive and long-lived Docker
- [AGENTS.md](AGENTS.md) — operating a running identity (for humans and
  coding agents): paths, logs, health checks, sharp edges
- [web/](web/README.md), [slack/](slack/README.md),
  [telegram/](telegram/README.md) — the dashboard and the chat bridges
- [deploy/](deploy/README.md) — running an agent on a dedicated box
  (systemd units, terraform, operations)

## Acknowledgements

The recursive language model idea in `shellm` comes in part from the
[Recursive LLM](https://github.com/andyk/recursive_llm) experiment (April
2023) and from Alex Zhang's [Recursive LM
(RLM)](https://alexzhang13.github.io/blog/2025/rlm/) project (October
2025). The continuous thinking behind Headlong's persistent agency — and
its name — come from the [Headlong](https://github.com/andyk/headlong)
research project.

## License

[Apache 2.0](LICENSE). Copyright 2026 Laude Institute.
