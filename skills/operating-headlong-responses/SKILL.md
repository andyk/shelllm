---
name: operating-headlong-responses
description: Operates Headlong Responses completions, lifecycle state, Conversations, compaction and WebSocket transport. Use for typed inference workers, long operations, resumable sessions, or recovery from uncertain delivery.
---

# Operating Headlong Responses

Choose an explicit execution/state mode, validate terminal results, and preserve
uncertainty instead of replaying possibly accepted work.

## Choose the boundary

- `llm`: one completion. Use for extraction, classification, drafts, typed
  function-call output, and inference subordinate to an application coordinator.
- `shellm`: executes model-generated Bash in a loop. Use for sandboxed code or
  file investigations, not merely to get a completion string.
- `responses`: inspect or mutate existing remote lifecycle state.
- `responses-ws`: optional uv transport; a broker amortizes connections, but is
  not a durable job queue, authorization service, or server cancellation API.

The embedding application owns authorization, tenant scoping, task leases,
result publication and business state. Metadata and model output do not grant
authority. This skill grants no permission to spend, publish, delete, or cancel.

## Preflight

1. Confirm the authorized task, model/provider, input scope and spend bound.
   Use a sandbox for shellm and a dedicated capped key. Do not print secrets.
2. Read `llm --help`, `responses --help`, `shellm --help` for installed behavior.
   Inspect process environment and relevant `.env` configuration without dumping
   values. Explicit environment wins. Avoid an ambient endpoint/key reroute.
3. Native OpenAI uses `OPENAI_API_KEY`; compatible endpoints use `LLM_API_KEY`
   and `LLM_API_URL`. Lifecycle operations must use the original account/provider/
   endpoint. OpenRouter completion support does not imply lifecycle support.
4. Set `LLM_MAX_TIME`, output-token cap and a private result directory. Reserve
   a distinct `LLM_RESPONSE_FILE` and `LLM_USAGE_FILE` per concurrent call. Keep
   stdout, stderr and sidecar separate; never execute streamed partial text.
5. Pick exactly one state owner: process-local continuation/replay, or a
   Conversation. Reject incompatible combinations before dispatch.

## Make one call and classify its result

```bash
# Paid request: only after task/spend authorization; input is a JSON item array.
LLM_API_FORMAT=responses LLM_RESPONSE_FILE=/private/run/response.json \
LLM_USAGE_FILE=/private/run/usage.json LLM_MAX_TIME=60 \
  llm --provider openai -m gpt-5.4-mini --no-stream --messages-file /private/input.json
```

- Successful protocol completion requires completed/incomplete status, a
  nonempty ID, output array and no error. Incomplete is partial, not a complete
  application answer. Validate schema/refusal/tool results before publication.
- llm preserves typed function calls but does not execute your functions.
  Shellm cannot dispatch native function-only results as shell commands.
- Responses CREATE is never automatically retried by llm. Lost acknowledgements,
  missing terminal events and malformed success bodies can be `outcome_unknown`.
  Stop and reconcile; do not turn absence of text into permission to retry.
- A structured, pre-generation previous-ID rejection permits shellm's one replay
  fallback. Known response IDs, terminal failures and unknown outcomes do not.

## Long-running inference and recovery

Use `LLM_RESPONSES_BACKGROUND=1` over HTTPS only when the endpoint supports it.
Known IDs can be polled/resumed; `LLM_RETRIES` bounds retrieval/resume attempts,
not new creates. One deadline covers create, poll, resume and backoff.

Interruption/deadline/exhaustion triggers best-effort cancellation with up to
five extra seconds. Only a same-ID terminal result confirms settlement; only
`cancelled` confirms cancellation. A completed result may win the race. Preserve
unknown outcomes and IDs. Without an ID, automatic reconciliation is unavailable.

Authorized inspection: `responses get ID`, `responses input-items ID --all`,
`responses conversations items CID --all`. Stream retrieval exits 0 on delivery
of any terminal event, including failed/cancelled; inspect the event's status.
`--all` fails on incomplete/broken pagination rather than certifying exhaustion.
Cancel/delete/add/update/remove mutate remote state; obtain appropriate authority.
Never automatically delete recovery evidence after an error.

## Sessions, transport, and context

- `SHELLM_RESPONSES_CONVERSATION=new` creates server state; `--resume`/`--traj`
  reuses the latest Conversation when the setting is new or empty/unset. A
  different literal ID redirects the session. For fresh state use a new
  trajectory. Reject body-file Conversations; use the dedicated setting.
- Sent-step checkpoints are in the effective trajectory directory's
  `.responses-conversations/`, private and atomically replaced, with a local
  exclusive whole-run lock. In-flight, missing, mismatched checkpoints and stale
  locks fail closed. Reconcile server items and trajectory before reuse. Do not
  delete a lock and guess. This is not fsync/power-loss or distributed durability.
- Ordinary non-Conversation replay/IDs disappear with the process; resumed
  shellm rebuilds from trajectory, not persisted exact typed output. Child calls
  and summaries do not inherit the parent's Conversation.
- WebSocket uses uv plus pinned websockets, supports only underlying OpenAI or
  compatible providers, and rejects background/privacy-policy combinations it
  cannot honor. Shellm retains provider/key/endpoint semantics and rejects a
  transport-only URL. A configured dead broker never falls back to one-shot.
- Broker bounds: 16 active requests, 32 local clients, 16 MiB frames, 64 events/
  16 MiB per lane. Abandonment retires the connection; other unsettled calls may
  also fail unknown. Never assume a closed connection cancelled provider work.
- Compaction mode `auto` uses native OpenAI server compaction, otherwise
  standalone; `server` declares support; `standalone` forces replay. Retention
  and capability are independent; native server compaction supports store=false.
  Conversation compaction requires server support. Keep newest server marker,
  but standalone output **as-is**. Standalone failure disables upkeep for the
  run; upkeep uses remaining completion time and records reported usage.
- Choose a compaction threshold with headroom for future input/output. Keep
  constraints, provenance and application decisions outside opaque compaction.
  store=false is not a ZDR or deletion guarantee.

## Learn more and verify

In a checkout read `docs/responses-guide.md`, its executable example
`docs/examples/responses-request.sh`, and `design/responses-lifecycle.md`.
For an installed copy, find the checkout in the state home's `app_dir`; if it is
gone, rely on installed `--help` and this skill rather than assuming docs exist.
Load `operating-headlong` for identity/dispatcher/core operations.

Run `tests/run-all.sh responses` from a checkout for synthetic protocol faults;
run the full harness before changing shared core behavior. Distinguish local
stub/server evidence from live-provider conformance. Never run paid smoke tests
without an approved provider/model/input/spend scope.
