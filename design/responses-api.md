# OpenAI Responses completion protocol

Status: implemented 2026-09-01.

## Scope

Headlong's completion boundary remains `bin/llm`. Chat Completions remains the
default. Operators opt into the OpenAI Responses create protocol with
`LLM_API_FORMAT=responses` for the `openai`, `openrouter`, or
`openai-compatible` providers.

This change covers synchronous buffered and SSE response creation, including
reasoning summaries, function call items and outputs, structured and
multimodal input items, terminal status and errors, usage, and continuation.
Response retrieval/deletion/cancellation, input-item listing, Conversations,
and WebSocket mode are separate lifecycle work (design/responses-lifecycle.md).
Background responses live in `bin/llm` because the caller still receives one
terminal object per call: llm polls or resumes the stream itself and cancels
the job when it is killed or out of time; the contract is in that document.

## Wire contract

- Native OpenAI defaults to `https://api.openai.com/v1/responses` in Responses
  mode. OpenRouter defaults to `https://openrouter.ai/api/v1/responses`, and
  the `LLM_OR_*` routing and privacy constraints ride the Responses payload
  exactly as they ride chat (merged into any caller-supplied `provider`
  object). `openai-compatible` still requires the exact `LLM_API_URL`
  endpoint.
- The existing messages input is passed as the Responses `input` array without
  reshaping. This preserves typed input/output items, images, files, assistant
  phases, reasoning items, function calls, and `function_call_output` items.
- The system prompt maps to `instructions`, the token cap maps to
  `max_output_tokens`, and an explicit thinking level maps to
  `reasoning.effort` with an automatic summary.
- `LLM_RESPONSES_BODY_FILE` may name a JSON object containing other synchronous
  create fields. `bin/llm` owns and overwrites `model`, `input`, `instructions`,
  `max_output_tokens`, `stream`, and `previous_response_id` so command-line and
  continuation semantics remain deterministic. Conversation state is rejected
  because it conflicts with this continuation contract.
- Every create requests `reasoning.encrypted_content`, preserving exact
  reasoning-item replay for stateless and Zero Data Retention paths while
  retaining any other caller-supplied `include` values.
- `LLM_PREVIOUS_RESPONSE_ID` adds stateful continuation.
- `LLM_RESPONSE_FILE`, when set, receives the complete terminal Response object
  or provider error envelope through an atomic mode-0600 write. It is the
  machine-readable channel for response IDs, all output items, function calls,
  encrypted reasoning, status, errors, and usage. Its directory is checked
  before the request is sent, and a write that fails after a streamed reply
  fails the call rather than returning text without the promised artifact.

The human-output contract does not change: visible `output_text` is stdout,
reasoning summaries are stderr, and `--raw` prints the buffered API object.
A function-only response is a successful protocol response even though stdout
is empty; callers consume its items from `LLM_RESPONSE_FILE`.

## Streaming and failure semantics

The SSE handler emits text and reasoning deltas as they arrive, records the
terminal response from `response.completed`, `response.incomplete`, or
`response.failed`, and maps Responses usage into the existing usage record.
Incomplete responses warn with their reason. Failed responses and `error`
events fail the call.

Retries remain legal only before protocol output is emitted. A terminal output
item counts as output even when it is a function call with no visible text.
After a text, reasoning, or output-item event, a truncated or failed stream is
never replayed automatically.

The shared stream retry loop keeps its pre-existing rule for every protocol:
any failure before output is retried, whatever the handler's exit status (an
Anthropic overloaded error arrives as an in-stream event and exits 1). The one
exception is a rejected `previous_response_id`, which is deterministic. The
Responses handler reports it through a private exit code (`die_permanent`) so
the loop stops at once and `shellm` can fall back to its replay chain without
waiting through retries. That decision is made on the error body alone and
does not depend on `LLM_RESPONSE_FILE` being set.

`LLM_STOP_AFTER_CODE_BLOCK` keeps its contract in Responses mode: the stream
is cut when the first fenced block closes and the cut is a clean finish. The
terminal event never arrives, so no sidecar is written and usage is estimated.
`shellm` therefore does not request the cut in Responses mode, because its
continuation needs the terminal object.

## shellm continuation

Responses mode keeps completion state only for the current `shellm` process:

1. The first call sends the trajectory-derived context in full.
2. Later calls send only newly appended user-side context plus the stable
   instructions and the previous response ID. New rows are told apart from
   re-rendered ones by trajectory step id (`context --ids --no-merge`, one
   row per message), never by comparing rendered bytes: the render shrinks a
   row as it ages out of the newest block and slides its window, so byte
   prefixes drift while the rows themselves have not changed. Assistant rows
   are the model's own turns, already held by the response ID or the replay
   chain, and are never resent. Ids are stripped before anything reaches the
   provider.
3. In parallel, shellm retains the original input and every terminal output
   item. This exact replay chain preserves encrypted reasoning and assistant
   `phase` values for stateless endpoints and Zero Data Retention accounts.
4. If a continuation is rejected specifically because the previous response
   cannot be referenced, before any output is emitted, shellm retries once with
   the replay chain and remains stateless for the rest of the run. A call that
   already emitted text is not a rejection whatever its error says: the text
   is discarded and the run fails.
5. A resumed process starts a new chain from the durable trajectory. Remote
   response IDs are not persisted as durable trajectory state.

`SHELLM_RESPONSES_BODY_FILE` is mounted read-only into the Docker sandbox at
its host path, so nested `llm` and `shellm` calls inside the container read
the same file.

OpenRouter's Responses endpoint is stateless and therefore starts directly in
replay mode. Native OpenAI and generic compatible endpoints use automatic
stateful continuation with the safe replay fallback.

The existing thinking-text empty-response workaround remains the Chat
Completions behavior. In Responses mode, an incomplete reasoning-only Response
continues through its response ID or exact output-item replay instead of
turning a reasoning summary into an invented assistant message.

## Verification

Hermetic tests pin request JSON, endpoint selection, pass-through input,
extra-body validation and precedence, buffered extraction, terminal sidecar
permissions, response status and usage, SSE event classes, function-only
success, stateful shellm deltas, stateless replay, continuation fallback, and
unchanged Chat behavior. The implementation is additionally smoke-tested
against native OpenAI and an independent OpenAI-compatible Responses endpoint.
