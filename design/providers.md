# Providers

Status: DECIDED 2026-08-27 — the policy below governs provider additions.
The `openai-compatible` provider and the adapter seam are both
implemented in `bin/llm`.

Headlong keeps getting asked to support more model providers (PR #46,
issues #65 and #71). Each one is easy on its own, but core grows with
every provider we absorb, and there are a lot of providers. The policy
in this document says which providers go into core, which stay outside
it, and what the boundary between them is.

## The decision

1. `bin/llm` is the only code in the repo that calls a model provider.
   Every other tool (shellm, the thinkers, the bridges, the web dash)
   makes completions through it. Code elsewhere that calls a provider
   endpoint directly is wrong, with one standing exception: the dash
   reads OpenRouter's catalog and credit endpoints for display, which
   is not a completion path.

2. Core supports a provider when its wire protocol can be implemented
   and tested with a small bash, curl, and jq path — no other runtime,
   no SDK, no auth beyond a header. ("Plain HTTP and JSON" alone is
   too broad a test; nearly every provider meets it.) Most qualifying
   providers are covered by the generic `openai-compatible` provider,
   which is configured with a URL, a model name, and an optional key.
   After that, supporting a new compatible provider (Ollama, vLLM, LM
   Studio, Together, a corporate proxy) is a documentation entry, not
   code. A provider with a genuinely different wire format (the way
   Gemini has one) can still be added to core, but that is a maintainer
   decision, and the bar is high because the generic provider covers so
   much.

3. A provider that needs a subprocess, another language, an SDK, or
   auth that is not a key in a header lives outside core, behind the
   adapter contract below. The adapter carries its own dependencies.
   Core never gains a runtime dependency on an interpreter because of a
   provider.

4. Installer prompts, dash panels, and other integration beyond the
   completion path are decided per provider, case by case. Completion
   support is cheap and open; deeper integration is earned. An adapter
   gets no installer or dash integration by default.

## The openai-compatible provider

The provider is never auto-detected, because arbitrary model names
(`qwen3:8b`, `llama3.2`) imply nothing. Name it explicitly and give it
a URL:

```bash
LLM_PROVIDER=openai-compatible \
LLM_API_URL=http://localhost:11434/v1/chat/completions \
llm -m qwen3:8b "hello"
```

| Variable | Meaning |
|---|---|
| `LLM_PROVIDER=openai-compatible` | Selects the provider (or pass `--provider openai-compatible`) |
| `LLM_API_URL` | The exact chat-completions or Responses endpoint. Required, no default |
| `LLM_API_KEY` | Optional. When set, sent as `Authorization: Bearer` |
| `LLM_API_FORMAT` | `chat` (default) or `responses` |

What "compatible" means here, concretely: a chat-completions endpoint
that accepts `model`, `messages`, and `max_tokens`; non-streaming
responses carrying the text at `choices[0].message.content`; streaming
as SSE `data:` lines with deltas at `choices[0].delta.content`, ended
by `data: [DONE]`; and errors as non-2xx responses with a JSON body.
That subset is what the code exercises and the tests pin. An endpoint
that diverges from it is best effort — it may well work, but the
divergence is not a core bug to absorb.

With `LLM_API_FORMAT=responses`, compatibility instead means the synchronous
OpenAI Responses create protocol at the exact configured URL: typed `input`
items, terminal `output` items and status, Responses SSE events, and structured
errors. `LLM_RESPONSES_BODY_FILE` carries create fields beyond the completion
CLI's stable flags, while `LLM_RESPONSE_FILE` receives the full terminal object
or error envelope. Server-side lifecycle operations (retrieve, cancel, delete,
Conversations, background jobs, and WebSocket sessions) are not part of this
completion-provider seam.

`LLM_PROVIDER` is process-wide by design (decided 2026-08-26:
environment overrides are authoritative, never pattern-guessed around),
so selecting `openai-compatible` routes every completion in the
deployment — the main model, the responder, recap, memory search —
through the one endpoint. A mixed setup (a hosted main model plus a
cheap local one) needs an endpoint that proxies both models, or
per-call environment in the caller; there is no per-model routing.

Everything else in `bin/llm` applies unchanged: streaming, retries,
network guards, truncation warnings, the usage ledger, and the health
marker. Unknown model names get a 16384 default output cap under this
provider (the global 4096 fallback starves agentic steps);
`LLM_MAX_TOKENS` or `-t` overrides it.

Inside the Docker sandbox, `localhost` is the container, not the host.
A local inference server running on the host is reached at
`host.docker.internal` on macOS, or the docker bridge address on Linux.

## The adapter contract

An adapter is one executable that turns a completion request into
provider output. `bin/llm` runs it in place of curl when the operator
configures it:

```bash
LLM_PROVIDER=adapter
LLM_ADAPTER=/path/to/executable
```

The contract, implemented by the invoker in `bin/llm` (pinned by
`tests/test_llm_adapter.sh`):

- `bin/llm` runs `$LLM_ADAPTER` with these flags: `--model NAME`,
  `--max-tokens N`, and, when set, `--effort LEVEL`, `--thinking
  [LEVEL]`, and `--no-stream`. The system prompt arrives via
  `--system-prompt-file PATH`. The messages array (the same JSON shape
  `llm -M` takes) arrives on stdin.
- `LLM_API_FORMAT=responses` is legal for the adapter provider. `bin/llm`
  then adds `--api-format responses` to the argv, and stdin carries typed
  Responses `input` items rather than a chat messages array. The adapter
  owes the Responses contract in return: text deltas on stdout, reasoning
  summary deltas on stderr, the terminal Response object or error envelope
  written to `LLM_RESPONSE_FILE` (atomic, mode 0600), and the same reading
  of `LLM_PREVIOUS_RESPONSE_ID` and `LLM_RESPONSES_BODY_FILE` that
  `bin/llm`'s own builder does, including the caller's body as the base and
  the always-requested `reasoning.encrypted_content`. Those three variables
  are exported to the adapter. Chat adapters never see `--api-format`.
  `tools/responses-ws` is the adapter this exists for.
- The adapter writes response text to stdout, streamed as it is
  produced, and diagnostics to stderr. It exits 0 on success and
  nonzero on failure with a one-line reason on stderr. It must not
  print partial text and then exit nonzero unless the failure really
  happened mid-generation.
- Usage reporting: when the environment carries `LLM_USAGE_FILE`, the
  adapter writes one JSON object to that path, with any of `in_tok`,
  `out_tok`, `think_tok` as integers. `bin/llm` stamps the ledger from
  it. An adapter that cannot count tokens writes nothing.
- `bin/llm` wraps the adapter in its own wall-clock deadline
  (`LLM_MAX_TIME`). The adapter runs in its own process group; on
  expiry `bin/llm` TERMs the group, waits a 5s grace, then KILLs the
  group — the adapter's children included, so nothing it spawned can
  outlive the deadline holding stdout — and reports the call as an
  error even if the adapter manages to exit 0 on the way down. The
  adapter does not need its own outer timeout, but it should pass
  reasonable deadlines to whatever it calls.
- Retries: the invoker runs the adapter once; a nonzero exit fails the
  call, with the exit code reported and the health marker updated. An
  adapter that wants retries does its own, under the deadline above.
  (The curl path's rule — retry only when nothing was emitted — can
  extend to adapters later if a real need shows up.)
- The health marker (`llm_health.json`) is written by `bin/llm` from
  the exit status, never by the adapter, and `ok` is only recorded
  after the adapter exits 0.
- Sandbox: `LLM_ADAPTER` is used as given, and it must name an
  executable that exists inside the container for sandboxed callers,
  which means the operator mounts it at the same path. A missing or
  non-executable adapter fails with a clear message before anything
  runs.

An adapter is trusted local code. `bin/llm` runs it with the caller's
full environment, provider keys included — there is no isolation
between an adapter and the process that invokes it. Point
`LLM_ADAPTER` only at code you trust as much as `bin/llm` itself.

Language, dependencies, packaging, and auth storage are the adapter's
business. An adapter that needs `python3`, an npm package, or a
logged-in vendor CLI declares that in its own documentation, and a
machine without those things loses that adapter and nothing else.

## Why the line is drawn here

The completion path is one choke point, so an adapter seam in `bin/llm`
covers every caller at once. The expensive part of an in-core provider
was never the payload builder, which for OpenAI-compatible providers is
a one-line alias. The expensive part is everything around it: the
installer's key detection and default-model tables, the dash's model
config, the sandbox mount list, the docs, and the review surface of new
code on the path every thought travels. Keeping core to "HTTP and JSON,
one generic entry for the compatible majority" caps that cost at
roughly its current size while keeping every provider reachable.
