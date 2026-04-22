# The Shell is Back at the Center of Computing

In 1971, Ken Thompson wrote the first Unix shell. It was a command interpreter — a thin loop that read a line, found a program, ran it, and waited. That's all it did. That was enough.

Over the next decade, the shell became the connective tissue of an entire philosophy of computing. Doug McIlroy articulated it most concisely: write programs that do one thing well, write programs to work together, write programs that handle text streams because that is a universal interface. These weren't arbitrary aesthetic choices. They were engineering observations about what made systems composable, debuggable, and resilient.

Then the world moved on. GUIs won. The web won. The shell retreated to a power-user niche — beloved by sysadmins and backend engineers, ignored by everyone else. For most of the software industry, the terminal became a place you visited reluctantly to run `git push` or restart a Docker container.

I think LLMs are bringing it back. And I think the shell isn't just a good environment for AI agents — I think it's the *right* one. The one that will win.

## Why the shell fits LLMs better than you'd expect

There's a structural alignment between how LLMs work and how the Unix shell works that I don't think has been fully appreciated yet.

An LLM is, at its core, a thing that reads text and writes text. The Unix shell is an environment where *everything* is text. Stdin, stdout, stderr, environment variables, files, pipes — the universal interface is streams of bytes, and in practice that means streams of text. An LLM dropped into a shell can immediately talk to every tool in the environment using the protocol those tools already speak.

Compare this to the current dominant paradigm for LLM tool use: hand-crafted function schemas, JSON argument marshaling, bespoke API wrappers. Every tool needs an adapter. Every adapter needs maintenance. The function-calling approach treats the LLM as a dispatcher that picks from a curated menu of capabilities.

The shell treats the LLM as an *operator* — someone sitting at a terminal with access to the entire system. `curl` is the HTTP client. `jq` is the JSON processor. `python3 -c` is the escape hatch for anything else. No schemas to define. No wrappers to write. The LLM composes tools the same way a human would: by piping them together.

This is McIlroy's vision, realized through a medium he couldn't have anticipated. The "universal interface" of text streams turns out to be exactly the interface LLMs are native to.

## Composition over enumeration

The function-calling approach to LLM tooling has an enumeration problem. You define the tools the model can use ahead of time: `search_web`, `read_file`, `run_sql`. The model picks from the list. If your list doesn't include something, the model can't do it.

The shell inverts this. Instead of enumerating capabilities, you provide a *composable environment* and let the model figure out what to do. Need to fetch a webpage, extract all the links, filter them by domain, and count them? That's a one-liner:

```bash
curl -s "$URL" | grep -oP 'href="\K[^"]+' | grep "$DOMAIN" | wc -l
```

No one defined a `count_links_by_domain` tool. The capability emerged from composition. This is the GNU philosophy in action — small, sharp tools connected by pipes — and it turns out to be an incredibly natural fit for how LLMs reason about multi-step tasks. The model doesn't need to know every tool in advance; it knows the *grammar* of composition, and that's enough.

## shellm: an LLM that lives in bash

This line of thinking led me to build [shellm](https://github.com/andyk/shellm) — a recursive LLM that operates inside a bash shell. It's a port of Alex Zhang's [Recursive Language Models](https://alexzhang13.github.io/blog/2025/rlm/) concept, reimplemented in bash, for bash.

The idea is simple. shellm runs a loop:

1. Send context to Claude with a system prompt that says "write bash code"
2. Claude responds with a ```bash code block
3. Execute the code (in Docker if available, locally otherwise)
4. Stream the output back as the next message
5. Repeat until the code signals completion or hits the iteration limit

The LLM has full shell access. It can curl APIs, parse JSON with jq, write Python scripts on the fly, install packages, read and write files — whatever the task requires. When it has an answer, it sets `FINAL="the answer"` and the loop terminates.

The entire thing is a single bash script. The only dependencies are bash, jq, and curl. There's no framework, no package.json, no virtual environment. It's a shell tool built out of shell tools.

```bash
# Set your API key and go
export ANTHROPIC_API_KEY="sk-ant-..."

# Ask a question
shellm what is the mass of jupiter in kilograms

# Pipe data in
cat dataset.csv | shellm summarize this data and find outliers

# Pass files as context
shellm -f paper.pdf -f notes.txt compare these documents
```

## Watching it think

One of the things I find most compelling about this approach is the transparency. Every iteration, you see exactly what the LLM is doing — the bash commands it writes, the output it gets back, and how it adapts. There's no black box.

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

This is closer to how you'd debug a colleague's work than how you'd debug an AI agent. You can see the reasoning embodied in the commands: why it chose to curl that endpoint, what it did with the response, when it decided it had enough information.

## Recursion: LLMs calling LLMs

Code generated by shellm can call shellm itself. There are two modes:

**`shellm "prompt"`** starts a fresh sub-loop with its own workspace. It's a clean delegation — give a subtask to a new agent, get the result back through stdout.

**`shellm --fork "prompt"`** is more powerful. It forks the entire conversation history and workspace into a new sub-loop. The sub-agent gets full context of everything that's happened so far, plus its own independent copy of all workspace files.

This is recursive decomposition using the shell's own primitives. The parent process delegates a subtask, the child process runs its own think-execute loop, and the result flows back through stdout — exactly like any other Unix pipeline. No orchestration framework required. The shell's process model *is* the orchestration framework.

Recursion depth is capped (default 3) to prevent runaway API costs. But within that, you get genuine multi-agent behavior: a shellm process that researches a topic can fork sub-agents to handle different aspects in parallel, each with their own workspace, all coordinated through the filesystem and stdout.

## Docker as a sandbox

By default, if Docker is running, shellm executes all generated code inside a container. The LLM can `apt-get install` whatever it needs, write files anywhere, run services — none of it touches your host system. The workspace directory is bind-mounted in, so files persist across iterations and flow back to the host.

This matters because the whole point is to give the LLM real autonomy. If you're going to let it run arbitrary bash, you want a sandbox. Docker provides exactly that, and shellm detects it automatically — no configuration needed.

## From tool to agent: mem, skills, and shelly

shellm is a powerful primitive, but it's stateless. Each run starts fresh. It has no memory of what happened last time, no learned abilities, no persistent identity. It's a tool, not an agent.

To get from a tool to an agent, you need three things: memory, skills, and a way to tie them together across conversations. So I built three more shell tools.

### mem: identity as text files

`mem` is a CLI memory store. It saves memories as individual markdown files with YAML frontmatter — a summary, a type (fact, belief, value, todo, preference...), and a timestamp. That's it. No database. No vector store. Just files in a directory.

```bash
mem add --type fact "My dad's name is Andy"
mem add --type preference "I prefer concise answers"
mem add --type todo "Learn how to write a SKILL.md"
mem search "what do I know about Andy"
mem dump
```

The search command pipes all memories through shellm itself for semantic matching — the tool composes with the tool. But you can also just `grep` the memories directory, because they're text files. Every piece of infrastructure is inspectable, greppable, and editable with any text editor.

This is the Ken Thompson way. Memory isn't a feature of a monolithic agent framework. It's a directory of files managed by a small, sharp program that reads stdin and writes stdout.

### skills: learned abilities as markdown

`skills` manages a local directory of skills following the [SKILL.md open standard](https://github.com/andyk/shellm). Each skill is a directory with a `SKILL.md` file — YAML frontmatter for metadata, markdown for instructions. Skills can be installed from GitHub repos, created locally, searched, and listed.

```bash
skills --install owner/repo     # install from GitHub
skills --init my-new-skill      # scaffold a new one
skills --show code-review       # read a skill's instructions
skills                          # list what's installed
```

Skills are to an agent what recipes are to a cook. They're reusable instruction sets that encode how to do specific things well. The key insight: skills don't require any special runtime. A skill is a text file that the LLM reads and follows. The "execution engine" for a skill is the LLM's ability to read instructions and generate code. No plugin API, no SDK, no registration step.

### shelly: a conversational agent in 700 lines of bash

`shelly` ties it all together. It's a multi-turn conversational agent that wraps shellm, mem, and skills into a stateful chat experience with session management.

```bash
shelly                          # start a REPL
shelly send "what files are in this directory?"
shelly send "what did I just ask you?"   # multi-turn memory
shelly new                      # fresh session
shelly sessions                 # list all sessions
shelly history                  # see the conversation
```

Each shelly session maps to a single shellm workspace. The first message creates the workspace; subsequent messages resume it with `--continue`, so the LLM sees the full conversation history. Memories and skills live inside each session directory:

```
.shelly/
├── sessions/
│   ├── current -> 2026-04-14-22-25-33_abc123
│   └── 2026-04-14-22-25-33_abc123/
│       ├── history.jsonl
│       ├── context.txt
│       ├── memories/
│       ├── skills/
│       └── run/            # shellm workspace
│           ├── .messages.json
│           └── .final
└── system_prompt.txt       # optional personality override
```

shelly doesn't override shellm's system prompt. Instead, it assembles a context block — personality, current memories, available skills — and prepends it to each user message. shellm's own execution mechanics (the code-execute loop, FINAL signaling, Docker sandboxing) stay intact. shelly just gives the LLM a richer picture of who it is and what it knows.

The result is an agent that can:

- Remember things you tell it across turns (`mem add`)
- Learn new skills at runtime (`skills --install`)
- Read its own source code to understand how it works
- Run arbitrary shell commands to accomplish tasks
- Compose with any tool in the Unix ecosystem

And it's all bash scripts. The whole stack — shellm, mem, skills, shelly — installs with:

```bash
./install.sh    # or ./install.sh --symlinks for development
```

No node_modules. No pip install. No Docker required (though shellm uses it for sandboxing when available). Four executables in `/usr/local/bin`.

## The Thompson test

Here's how I think about whether an agent architecture is on the right track. I call it the Thompson test, after Ken:

1. **Can you understand every component in an afternoon?** Each of these tools is a single bash script. shellm is the largest at ~1000 lines. You can read every line of code that comprises the entire agent.

2. **Can you compose the pieces in ways the author didn't anticipate?** mem is just a CLI that manages files. You can pipe its output into anything. Skills are markdown files — editable, greppable, version-controllable. shellm can call itself. None of these composition patterns were "designed in" — they fall out of the Unix interface naturally.

3. **Is the state inspectable?** Every piece of state is a text file on disk. Conversation history is JSONL. Memories are markdown with YAML frontmatter. The system prompt is a `.txt` file you can cat. There's nothing hidden in a database, nothing serialized in a binary format, nothing locked behind an API.

4. **Can you swap any component?** Want a different memory system? Point `MEM_DIR` at a different directory. Want a different LLM? Set `SHELLM_MODEL`. Want a different personality? Edit `system_prompt.txt`. Want to skip Docker? `--no-docker`. The architecture is decoupled because the coupling mechanism is the filesystem and environment variables — the oldest, most battle-tested integration protocol in computing.

Most modern agent frameworks fail the Thompson test. They have opaque state management, non-composable architectures, heavy runtimes, and components that only work together through proprietary interfaces. They're building cathedrals when we need bazaars.

## The terminal is the agent runtime

There's a broader argument here that I think matters: the terminal isn't just a *good* environment for AI agents — it might be the *winning* one.

The agent paradigm we're entering needs a few things: a way for LLMs to take actions in the world, a way to compose those actions, a way to persist state across interactions, and a way to keep humans in the loop. The terminal provides all of these, and it provides them through mechanisms that have been debugged over fifty years.

The action layer is the shell itself — every program on the system is a potential tool. The composition layer is pipes and process substitution. The state layer is the filesystem. The human-in-the-loop layer is the terminal's native interactivity — you can watch every command, interrupt with Ctrl-C, inspect any file.

Compare this to the web-based agent paradigm: browser automation through Playwright or Puppeteer, actions defined through API schemas, state managed by application-specific databases, human oversight through dashboards and approval queues. It works, but every piece is bespoke. The terminal's version of each layer is universal and pre-existing.

I'm not arguing that every agent should be a bash script. I'm arguing that the *design principles* of Unix — small composable tools, text as the universal interface, the filesystem as the state layer, transparency as a first-class property — are the right principles for building agent systems. And the easiest way to honor those principles is to actually use the system that embodies them.

Ken Thompson's shell was a thin loop: read a line, find a program, run it, wait. shellm is a thin loop too: read a message, ask the LLM, run the code, repeat. shelly adds memory and skills to that loop. Fifty-five years later, the pattern still works. It just needed a new kind of user.

The shell is back. This time, it's the agent runtime.
