# OpenAI Responses lifecycle operations

Status: fork-only work on 24601/headlong, stacked on the Responses completion
protocol (design/responses-api.md, upstream PR #101). Nothing here is proposed
upstream until that PR lands and the pieces have run for a while.

## Why a second surface

`bin/llm` is the completion boundary: one request, one terminal object. The
Responses API also has server-side state with its own life: a stored response
can be fetched, cancelled, deleted, and its input items listed; a Conversation
is a durable container that never expires; a background response runs after
the request returns; compaction rewrites a long window into an opaque item;
WebSocket mode keeps a connection open across turns. Those are operations on
state, not completions, so they get their own tool, `bin/responses`, and the
completion path learns only what it needs to cooperate with them.

Provider scope is native OpenAI first. OpenRouter's `/responses` is stateless
(no retrieve, cancel, delete, conversations); `bin/responses` does not special
case it, the endpoint's own 404 is the answer. `openai-compatible` endpoints
get the same paths relative to their configured base.

## bin/responses

One bash tool, curl and jq only, sharing `bin/llm`'s environment: the vendor
keys, `LLM_PROVIDER` / `--provider` (default `openai`), `LLM_API_URL` (when set
its `/responses` suffix is stripped and the rest is the API base), and the net
guards `LLM_CONNECT_TIMEOUT` and `LLM_MAX_TIME`. Stdout is the machine channel:
the API object exactly as returned, one JSON document per command (compact,
`--pretty` for humans). A non-2xx reply prints `responses: error: <message>` on
stderr, writes nothing to stdout, and exits 1. Exit 2 is a usage error.

```
responses get ID [--include V]... [--stream] [--starting-after N]
responses cancel ID
responses delete ID
responses input-items ID [--after ID] [--limit N] [--order asc|desc] [--include V]... [--all]
responses compact --model M (--input-file F | --previous-response-id ID) [--instructions S] [--body-file F]
responses conversations create [--items-file F] [--metadata JSON]
responses conversations get CID
responses conversations update CID --metadata JSON
responses conversations delete CID
responses conversations items CID [--after ID] [--limit N] [--order asc|desc] [--include V]... [--all]
responses conversations add CID --items-file F [--include V]...
responses conversations item CID ITEM_ID
responses conversations remove CID ITEM_ID
```

Paths and verbs, from the API reference (verify against
developers.openai.com/api/docs/api-reference before pinning a test):

| command | request |
|---|---|
| get | `GET /responses/{id}` with `include[]`, `stream`, `starting_after` |
| cancel | `POST /responses/{id}/cancel` (background responses only; idempotent) |
| delete | `DELETE /responses/{id}` returns `{id, object:"response", deleted:true}` |
| input-items | `GET /responses/{id}/input_items` with `after`, `limit` (1-100, default 20), `order` (default desc), `include[]`; list object with `data`, `first_id`, `last_id`, `has_more` |
| compact | `POST /responses/compact` with `model`, `input` or `previous_response_id`, `instructions`; the reply's output window starts with a `compaction` item carrying `encrypted_content` |
| conversations create | `POST /conversations` with `items` (max 20), `metadata` |
| conversations get / update / delete | `GET`, `POST` (`metadata` only), `DELETE /conversations/{cid}` |
| conversations items / add / item / remove | `GET`, `POST` (`items`, max 20), `GET`, `DELETE` under `/conversations/{cid}/items` |

`--all` follows `has_more` with `after=<last id>` and prints one merged list
object. `--stream` on `get` prints each SSE `data:` payload as one JSON line
and exits 0 only after a terminal event (`response.completed`, `.incomplete`,
`.failed`, `.cancelled`); this is the resume channel for background streams.

Tests (`tests/test_responses_cli.sh`): a curl stub records method, URL, and
body; pin each path, query encoding of repeated `include`, `--all` pagination,
the error contract, and that keys never appear on argv. Runs under bash 3.2.

## Background responses (bin/llm)

Status: implemented (`tests/test_llm_responses_background.sh`).

Opt in with `LLM_RESPONSES_BACKGROUND=1`, or `background: true` in the body
file (no longer rejected); `0` forces foreground over the body file. `store`
is left to the caller; the API keeps the data it needs for polling either way.
The retrieve and cancel URLs are derived from the create URL by stripping its
`/responses` suffix, so the create endpoint must end that way.

- Streaming create: `background: true, stream: true`. The handler remembers
  the response id from the first event carrying `.response.id` and the
  `sequence_number` of every event. If the stream drops before a terminal
  event (curl error, or EOF without one), llm does not re-create: it resumes
  with `GET /responses/{id}?stream=true&starting_after=N`, up to `LLM_RETRIES`
  times, and nothing already emitted is emitted twice. Only a drop before any
  id is known falls back to the ordinary retry.
- Non-streaming create: the reply is `queued` or `in_progress`; llm polls
  `GET /responses/{id}` every `LLM_RESPONSES_POLL_INTERVAL` seconds (default 2,
  backing off to 10) until a terminal status or `LLM_MAX_TIME`, then treats the
  object exactly like a buffered terminal reply (sidecar, usage, text).
- Cancel: while a background response is in flight, SIGINT, SIGTERM, and the
  `LLM_MAX_TIME` deadline POST `/responses/{id}/cancel` best effort (short
  timeout) before exiting non-zero, so a killed run does not leave a billable
  job behind. `cancelled` is a terminal status: no text, warning on stderr,
  sidecar written, exit non-zero.
- shellm: `SHELLM_RESPONSES_BACKGROUND=1` passes through. Its continuation
  contract is unchanged because a terminal object still arrives.

Tests extend `tests/test_llm_responses.sh`: queued then in_progress then
completed by polling; a dropped stream resumed with `starting_after` and no
duplicated text; TERM during a job records a cancel POST.

## Conversations

`bin/llm` accepts `conversation` from the body file, or
`LLM_RESPONSES_CONVERSATION=<conv id>`, when `LLM_PREVIOUS_RESPONSE_ID` is
empty; both at once is still an error, because the API rejects the pair.

`bin/shellm`: `SHELLM_RESPONSES_CONVERSATION=new|conv_...` chooses server-held
state instead of the process-local chain. `new` creates a conversation at run
start (`responses conversations create`). The id is recorded in the
`shellm-run` header row as `conversation`; unlike response ids, this is
durable on purpose (Conversations never expire) and a `--resume` of that run
reuses it. Each call sends only the new items with `conversation` set and
never `previous_response_id`; the replay chain is not kept. A missing or
rejected conversation fails closed with a clear error: the operator chose
durable server state, so there is nothing safe to fall back to.

Tests: llm rejects the pair and sends `conversation` alone; shellm creates on
`new`, carries the id on every delta, records it in the header, reuses it on
resume, and dies cleanly on a rejected conversation.

## Compaction

- `bin/llm`: `LLM_RESPONSES_COMPACT_THRESHOLD=N` adds
  `context_management: [{type: "compaction", compact_threshold: N}]` to the
  create body (owned when the variable is set, otherwise the body file's value
  stands). Server-side compaction then happens inside a normal turn.
- `bin/shellm`: `SHELLM_RESPONSES_COMPACT_THRESHOLD=N` (tokens). In stateful
  mode it passes through to llm. In replay mode (OpenRouter, ZDR, after a
  continuation fallback) shellm compacts itself: after a terminal response
  whose `usage.input_tokens` is at or above N, it runs `responses compact
  --model $SHELLM_MODEL --input-file <replay chain>` and replaces the chain
  with the returned window. In either mode, when a terminal `output` contains
  a `compaction` item, the replay chain is truncated to start at that item,
  which is what the API says to send next.

Tests: the threshold fires once per crossing, the replay file shrinks to the
compacted window and later requests begin with the compaction item; llm adds
`context_management` only when asked.

## WebSocket mode

An adapter, not core: `tools/responses-ws`, a Python script (`uv run`, PEP 723
metadata, `websockets`), following the adapter contract in
design/providers.md plus the Responses environment (`LLM_RESPONSE_FILE`,
`LLM_PREVIOUS_RESPONSE_ID`, `LLM_RESPONSES_BODY_FILE`). `bin/llm` allows
`--provider adapter` with `LLM_API_FORMAT=responses` and adds `--api-format
responses` to the adapter argv so the adapter knows the stdin JSON is typed
Responses input. The adapter's output contract is llm's Responses contract:
text on stdout as it streams, reasoning summaries on stderr, the terminal
object in the sidecar, usage in `LLM_USAGE_FILE`, exit non-zero on failure.

Two roles in one file. `serve` holds one connection to
`wss://api.openai.com/v1/responses` (60-minute lifetime, reconnects), listens
on a unix socket, multiplexes callers onto `stream_id` lanes (16 in flight, 32
named per connection), and exits when idle for `RESPONSES_WS_IDLE` minutes or
told `stop`. The default role is the per-call adapter: when
`RESPONSES_WS_SOCKET` names a live broker it forwards through it, otherwise it
opens a one-shot connection. shellm's `SHELLM_API_TRANSPORT=websocket` starts
the broker at run start (socket in rundir), points llm at the adapter, and
stops it at cleanup. Continuation via `previous_response_id` works through the
connection-local cache even with `store: false`; a
`previous_response_not_found` error takes the existing replay fallback.

Tests: a fake WebSocket server in the test itself (same library) checks the
`response.create` payload, streamed text order, the sidecar, an error event,
and broker multiplexing of two concurrent callers. If `uv` is absent the test
prints one skip line and exits 0, like the Docker-gated tests.

## Line budget

`cloc bin/ thinkers/` is capped by CI. These pieces add roughly 700 lines to
bin/; the cap moves to 11,500 on this fork in the first slice that crosses it,
which is the number the README already quotes.
