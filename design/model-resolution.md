# Model resolution

Status: COMPLETE — documents shipped behavior; the resolution chains match bin/llm, bin/shellm, bin/mem, and thinkers/_lib/common.sh.

**Status:** Current behavior (documented 2026-08-27)

How every LLM call in shellm decides which model to use, and where the
environment variables that feed that decision come from. Two layers:

1. **Resolution** — each call site walks a precedence chain of flags and
   env vars until one is set.
2. **Population** — the env vars themselves are filled in from `.env`
   files, with different (deliberate) merge semantics per tool.

There is no hard provider dependency anywhere: `bin/llm` picks the
provider from the model name (`claude-*` → Anthropic, `vendor/model` →
OpenRouter, `gpt-*`/`o*` → OpenAI, `gemini-*` → Gemini, `openai.gpt-*` →
Bedrock Mantle, and Bedrock-prefixed Anthropic/OpenAI IDs → Bedrock Runtime)
and each provider needs only its own credential. Bedrock accepts
`AWS_BEARER_TOKEN_BEDROCK`, standard AWS environment credentials, or an
`AWS_PROFILE` resolved afresh through AWS CLI. A model name that implies no
provider — a local OpenAI-compatible alias, say — is reached by setting
`LLM_PROVIDER` or passing `--provider`; an env value that contradicts a
name the harness *can* classify is still honored, but says so on stderr. Hardcoded `claude-*` names below
are last-resort defaults, reached only when nothing is configured.

## The knobs

| Variable | Meaning |
|---|---|
| `SHELLM_MODEL` | The system-wide model: agent loops and the default for everything below |
| `SHELLM_FAST_MODEL` | Optional cheap class for utility calls (summaries, `mem search`). Set it when `SHELLM_MODEL` is expensive; skip it when it's already cheap |
| `THINK_MODEL` | Per-thinker override (also settable per identity via `info.txt think_model=`) |
| `SHELLM_SUMMARY_MODEL` | Run-summary override; beats `SHELLM_FAST_MODEL` |
| `LLM_MODEL` | `bin/llm`'s own knob; equivalent to `-m` |
| `LLM_PROVIDER` | `bin/llm`'s provider override; equivalent to `--provider`. Needed when the model name implies no provider. A value that disagrees with what the name implies is honored, but warns on stderr |
| `AWS_BEARER_TOKEN_BEDROCK` | Amazon Bedrock API key; preferred Bedrock authentication |
| `AWS_PROFILE` | AWS CLI profile used to refresh Bedrock SigV4 credentials on each call |
| `AWS_REGION` / `AWS_DEFAULT_REGION` | Bedrock endpoint Region; then the AWS profile Region; defaults to `us-east-1` |

## Resolution chains

Left to right, first set value wins:

| Call site | Resolution chain |
|---|---|
| `mem search` | `SHELLM_FAST_MODEL` → `SHELLM_MODEL` → `claude-sonnet-4-5` |
| bare `llm` (no `-m`) | `-m` flag → `LLM_MODEL` → `SHELLM_MODEL` → `claude-sonnet-4-5` |
| run summaries (`bin/shellm`) | `SHELLM_SUMMARY_MODEL` → `SHELLM_FAST_MODEL` → *if run is `claude-*`*: `claude-haiku-4-5` / *else*: the run's own `SHELLM_MODEL` |
| `shellm` agent loop | `--model` flag → `SHELLM_MODEL` → `claude-opus-4-7` |
| thinkers (all) | `THINK_MODEL` → `SHELLM_MODEL` → `claude-opus-4-7` |
| web-started thinkers | `info.txt think_model=` → server-env `SHELLM_MODEL` → *(left unset — the step resolves as the thinker row above)* |
| `shellm-explore` report | `--model` flag → `SHELLM_MODEL` → `claude-opus-4-7` |
| `identity create` | `SHELLM_MODEL` → `claude-opus-4-7` |

The summary chain's provider split exists so that a non-Anthropic
deployment never falls back to a `claude-*` model it has no key for,
while Anthropic runs keep haiku's cheap summaries.

## Where the variables come from (.env population)

One merge semantic everywhere: **the real environment always beats `.env`
files** — loaders fill in only *missing* vars, never overwrite. (Until
2026-07-17 `bin/llm`/`bin/shellm` had clobbering loaders where cwd's
`.env` silently beat inline `SHELLM_MODEL=x shellm ...`; that footgun is
gone.) Files layer per variable, nearest layer wins:

- **`bin/llm` and `bin/shellm`**: cwd `.env` → `~/.shellm/.env`
  (`$SHELLM_CONF_DIR/.env` for shellm). A project `.env` that only pins
  a model still gets API keys from the home file.
- **Thinker step scripts** (`thinkers/_lib/common.sh`):
  `$IDENTITY_DIR/.env` → cwd `.env` → `~/.shellm/.env`. The web control
  plane's env wrapper has already sourced root + identity `.env`
  (identity wins) into the dispatcher's environment before any of this
  runs.

Consequences worth knowing:

- Inline env (`SHELLM_MODEL=x shellm ...`) and exported shell vars now
  reliably beat any `.env` file. Conversely: a stale `export
  ANTHROPIC_API_KEY=...` in your shell profile now beats the project
  `.env` — unset it or use flags.
- Changing *anything* in the box's `.env` — API key or model — needs a
  thinker stop/start: running dispatchers hold the environment they
  started with, and that environment now beats the file. (Previously key
  rotation was picked up per-call; model changes always needed a
  restart.)
- Identity-level `.env` overrides root for thinkers — if one identity
  mysteriously uses a different model/key, look there.
- Model selection should still travel via flags (`--model`, `-m`) rather
  than inline env when scripting: a flag beats every layer above and is
  immune to future loader changes.

## Choosing values (cost)

`SHELLM_MODEL` is the persona-quality knob; `SHELLM_FAST_MODEL` is the
cost knob. Utility traffic (summaries, memory search) is structured and
cheap-model-tolerant; background thinkers are the volume driver and stay
on the smart tier by default — pointing them at a cheap tier via
`THINK_MODEL` is a per-deployment persona decision, not a code default.
Examples:

```bash
# Anthropic, cost-conscious
SHELLM_MODEL=claude-opus-4-7
SHELLM_FAST_MODEL=claude-haiku-4-5

# OpenRouter, everything cheap (tiers pointless)
SHELLM_MODEL=openai/gpt-oss-120b

# Mixed quality: smart actor, cheap utilities
SHELLM_MODEL=z-ai/glm-5.2
SHELLM_FAST_MODEL=openai/gpt-oss-120b

# Amazon Bedrock Mantle (OpenAI Responses API)
AWS_BEARER_TOKEN_BEDROCK=...
AWS_REGION=us-east-1
SHELLM_MODEL=openai.gpt-5.6-sol

# Alternative: use a refreshable AWS CLI profile instead of the bearer vars
AWS_PROFILE=codex-bedrock
```
