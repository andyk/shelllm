# Outbound delivery: deliverable addresses, delivery notices, and a sent ledger

Status: Delivery 1 COMMITTED 2026-09-09 (address grammar, Slack notices,
chat validation). Delivery 2 BUILT the same day, tests green, pending commit
and deploy: `chat sent` over a `deliveries.jsonl` index (`bin/chat`), the
"Sent in the last 24h" wake prompt section (`_outbound_section` in
`thinkers/_lib/common.sh`, wired in `thinkers/monolith/step`, rule in
`prompt.md`), the 24h repeat refusal with `--force` in `chat send` and
proactive `chat reply`, and Telegram notices
(`telegram/src/headlong_telegram/outbound.py`). Tests:
`tests/test_chat_sent.sh`, `tests/test_monolith_wake_sections.sh`,
`telegram/tests/test_outbound.py`. The phone chat has no bridge process, so
its sends show as `unconfirmed` rather than `pending` (see part 7). Deploy
restarts both bridges through deploy/update.sh; `chat`, `_lib`, and the
monolith prompt reach Audel through the thinker sync.

Related: [conversation_memory.md](conversation_memory.md) part 5 is the
deferral index this design copies. [monolith_thinker.md](monolith_thinker.md)
covers the recent stream the monolith reads. [trajectory_spec.md](trajectory_spec.md)
is the step registry the new step type joins.

## The problem

An outbound message is an intention the mind writes down, not an act it can
see the result of. `chat send` appends a `message` step and exits 0. A bridge
process later reads that step and either posts it or does not, and nothing
comes back either way. The mind's only record that it spoke is its own
message step, and its only way to notice that it already spoke is to find
that step in the last 20 durable steps of its recent stream.

Both halves failed in the same week.

**Silent drops.** The Slack bridge delivers a message only when its `to`
parses as `slack-<user>-<channel>[-<thread ts>]`. Any other `slack-` name hits
a bare `continue` with no log line. Between 2026-09-05 and 2026-09-09 Audel
addressed 23 of 74 sends to a bare channel id (`slack-C0BMVH6LM4K`) or a bare
user id (`slack-U0BFD9NDVE3`), including most of the daily papers posts and
four DMs to Nick. None reached Slack. The bridge journal has zero warnings.
Audel's own memories from 2026-08-04 and 08-05 describe this exact rule and a
box-side fix that never reached main.

**Forgotten sends.** On 2026-09-08 Audel sent the same two papers four times
between 22:21 and 01:06 UTC. Between the first send and the second run's
prompt there were 16 idle runs, each adding an idle step and a final, so the
20-step window covered only 22:38 to 22:54 and the send had scrolled out.
The idle finals also repeated the stale plan ("queued Dr. Claw and RISE for
the 00:00 window"), reinforcing it. The fourth run tried to check with
`traj search`, which was killed by timeout on the 136K line log, and sent
anyway.

The responder's deferral index (conversation_memory.md part 5) already solves
the same shape of problem for inbound requests. A request is a structured
step, it is indexed over the whole trajectory, it is resolved by an explicit
marker, and the wake prompt lists the open ones however many steps have piled
on top. This design applies that shape to outbound messages.

## Design

### 1. Address grammar, in one place

`slack/src/headlong_slack/naming.py` owns the grammar. It accepts:

| form | meaning | delivery |
|------|---------|----------|
| `slack-<user>-<channel>-<ts>` | a channel thread | reply in thread |
| `slack-<user>-<channel>` | a DM channel, or a channel with no thread | top-level post in that channel |
| `slack-C…`, `slack-G…` | a bare channel id | top-level post in the channel |
| `slack-U…`, `slack-W…` | a bare user id | open the DM with `conversations.open`, post there |

The two short forms are what the mind writes when it means "post in
headlong-bot" or "DM Nick"; the bridge now does what was meant. The first
letter of a Slack id says what it is (U and W are users, C public channels,
G private channels, D DM channels), which is what makes the two-part forms
unambiguous.

`naming.py` exports the grammar as one regular expression string,
`NAME_RE_TEXT`, written in the subset that both Python `re` and bash ERE
accept (plain groups, no `(?:`). `bin/chat` carries the same string in a
variable `_SLACK_NAME_RE` on a marked line. `slack/tests/test_naming.py`
reads `bin/chat`, extracts that line, and asserts the two strings are equal.
That test is the mechanism that keeps chat and bridge in sync: a change to
one without the other fails CI.

### 2. `chat` rejects a malformed Slack target

`chat send`, `chat reply`, `chat send-file`, and `chat react` check any `to`
that starts with `slack-` against `_SLACK_NAME_RE` before appending, and die
with a non-zero exit and the accepted forms in the message. Names that do not
start with `slack-` are untouched, since other transports own them.

### 3. The bridge writes a delivery notice for every send

After handling a `message` step addressed to a `slack-` name, the bridge
appends one step to the root trajectory:

```json
{"type": "delivery", "source": "slack-bridge", "transport": "slack",
 "trigger_step": "<message step_id>", "to": "<the to name>",
 "status": "delivered", "channel": "C0BMVH6LM4K", "message_ts": "1757372480.123456",
 "permalink": "https://…/archives/C0BMVH6LM4K/p1757372480123456",
 "content": "delivered to slack-C0BMVH6LM4K"}
```

or, on failure,

```json
{"type": "delivery", "source": "slack-bridge", "transport": "slack",
 "trigger_step": "<message step_id>", "to": "<the to name>",
 "status": "failed", "reason": "unknown slack address form …",
 "content": "not delivered to slack-...: unknown slack address form …"}
```

Rules:

- `trigger_step` is the message step the notice is about, following the
  registry convention. A later reader resolves a send by matching it.
- The bridge writes the step by running `bin/traj append` on the identity's
  root trajectory, the same lock every other writer uses. It never opens the
  file for writing itself.
- A `to` that starts with `slack-` but fails the grammar gets a failed notice
  and a warning in the journal. A `to` for another transport is skipped as
  before, silently, because that transport's bridge owns it.
- Text posts and file uploads get notices. Reactions do not; they are not
  sends the mind needs to account for.
- The notice is keyed on the message step id. A bridge restart that replays
  a step writes a second notice for the same trigger, which readers treat as
  a duplicate, not a second delivery.
- The bridge already skips its own steps when following the log, because it
  only acts on `message` steps from the identity with `source: chat`.
- The permalink comes from `chat.getPermalink` and is best effort. It also
  gives `chat react --reply-to` a message timestamp for an outbound message,
  closing the gap where a reaction fell back to the thread root.
- Slack's `chat.postMessage` response carries `ts`; the notice records it as
  `message_ts` (`ts` belongs to `traj append`, which stamps every step; the
  first live notice on 2026-09-09 had the Slack value overwritten).

### 4. Who wakes up, and who sees it

The dispatcher wakes thinkers by step type. The monolith subscribes to
`observation`, `action`, `merge`, and its own wake step; the responder
subscribes to `message`. `delivery` is subscribed by nobody, so a notice
never wakes anything and cannot form a send-notice-send loop. A notice
written as a `message` would have made the responder answer it, and one
written as an `observation` would have woken the monolith after every send.

Failed notices are added to the monolith's recent stream filter
(`_recent_stream` in `thinkers/_lib/common.sh`), so a failure is visible at
the next wake even before the ledger exists. Delivered notices are not; they
would double every send in a 20-step window and are the ledger's job.

Waking the monolith on a failure is left off. It can be turned on later by
adding `delivery` to the monolith's subscriptions once notices have been
watched for a while.

The mid-run injection the dispatcher does for inbound messages (a `feedback`
step appended while the monolith is busy) is not extended to notices. That
path has been dead since the monolith moved to run scope on 2026-09-03,
because the feedback step carries no run id and run scope keeps only rows
that do, and its purposes are now covered by the responder and the deferral.
Retiring it is a separate change.

### 5. The sent ledger (delivery 2)

`chat sent [--since 24h] [--json]` lists the identity's outbound message
steps with their delivery state, newest first:

```
2026-09-08T22:21Z  slack-C0BMVH6LM4K  failed (unknown slack address form)  "Daily Paper — Dr. Claw…"
2026-09-07T00:02Z  slack-U0BFD9NDVE3-C0BMVH6LM4K  delivered  "Daily papers for 2026-09-07…"
2026-09-07T04:46Z  slack-U0BFD9NDVE3  pending 2d  "Built a reaction-memory cross-check…"
```

It is built the way `chat pending` is built: a derived index next to the
trajectory, `sent.jsonl`, maintained in the same incremental pass as
`messages.jsonl` and `deferrals.jsonl`, holding every outbound message step
and every `delivery` step. A send is `delivered` or `failed` when a notice
with its step id exists, and `pending` otherwise. A send that has been
pending longer than a few minutes means the bridge for that transport is
down or behind, which nobody can see today.

The monolith's wake prompt gains a short section, rendered from
`chat sent --since 24h`, one line per send with the destination, the state,
and the first few words. It is keyed by time, not by step count, so it
survives any number of idle wakes. It costs a few hundred bytes on a busy
day and nothing on a quiet one.

### 6. Send-time dedup (delivery 2)

`chat send` consults the same index and refuses to append a message whose
content matches one already sent to the same destination in the last 24
hours (`CHAT_REPEAT_WINDOW`), unless `--force` is given. The refusal names
the earlier send and points at `chat sent`. `chat reply` gets the same check
only when it answers nothing, i.e. no `reply_to` was given or inferred, which
makes it a proactive send into a conversation. A reply stamped to a specific
inbound is exempt, because two questions may deserve the same answer and the
responder must not be blocked from saying "still running" twice in a day.
The bridge's five-minute dedup stays as a backstop for a replayed step. This
moves the check the mind failed to make on 2026-09-08 into the tool, so the
mind does not have to remember to check.

### 7. Other transports (delivery 2)

The Telegram bridge writes the same `delivery` step with `transport:
telegram` and `source: telegram-bridge`, including failed notices for an
address that is not on its allowlist or names a group chat. The phone chat
has no bridge process: the web server serves messages straight from the
trajectory when the phone polls, so there is no moment that means
"delivered" short of the phone acknowledging, which it does not do today.
Its sends are shown as `unconfirmed` (a transport that never reports back)
rather than `pending` (a bridge that has not reported yet), so a stale
phone-chat send does not read as a bridge outage. If the phone client ever
acknowledges, the web server can write the same step.

## Small changes shipped alongside (2026-09-09)

- The recent stream drops an idle run's final, so a string of idle wakes
  collapses to one "idle xN" line instead of two steps per wake
  (`_RECENT_STREAM_PAIR_JQ`). This does not replace the ledger; it keeps
  idle wakes from eating the window.
- The dispatcher's mid-run `feedback` injection is removed (dead since run
  scope; the responder and the deferral cover its jobs). The pending file
  handoff is unchanged.
- A monolith run that dies with no durable step now records the last stderr
  lines in its `error` step (`stderr_tail`), so bursts like 2026-09-07 have
  a reason attached.
- `traj search` prefilters rows with one grep and takes `--tail N`, so a
  self-check on a long log finishes instead of being killed by timeout.
- `mem add` rejects a flag it does not know instead of storing it as the
  memory's first word.

## Incident on the first day (2026-09-09) and what it changed

Switching the Telegram bridge back from a scratch identity to Audel at 10:55
UTC handed it a cursor written for the other trajectory (its state dir is
shared across identities). `follow` treated the small offset as valid and
read Audel's whole 1.5 GB log, so the bridge re-sent 130 of the 183
historical Telegram messages to Nick before it was stopped at 11:29. Each
send took 31 seconds because the notice writer ran `bin/traj append` as the
bridge user, which has read-only access to the trajectory, and traj's lock
loop spun for the whole subprocess timeout instead of failing. Three
changes:

- `mindlog.follow` (both bridges) writes `<offset> <trajectory path>` and
  ignores a cursor for any other trajectory; a shrunk file resumes at its
  end instead of replaying from zero. A bridge must never replay.
- The notice writer checks that the trajectory and its directory are
  writable before spawning traj, and after one `PermissionError` disables
  notices for the run with a single log line. `bin/traj append` dies at
  once when it cannot create its lock directory.
- Because the Telegram bridge user cannot write the log by design (it keeps
  the bot token out of the agent's reach), Telegram notices are off on the
  box and `chat sent` shows Telegram sends as `unconfirmed`, not `pending`.
  Giving that user append rights on the trajectory, or routing the notice
  through the web API, would turn them on; neither is decided.

## What this does not do

- It does not give recurring goals a progress log. That is a separate design.
- It does not touch the run scope render.

## Rollout

Delivery 1, Slack only, one deploy with a bridge restart (deploy/update.sh
already restarts the bridge unit):

1. `naming.py` grammar and `NAME_RE_TEXT`; tests for the two short forms.
2. `outbound.py`: resolve bare users through `conversations.open`, post bare
   channels top-level, write notices, warn on bad addresses; tests with a
   fake client that returns `ts`.
3. `bin/chat`: `_SLACK_NAME_RE` and the target check in the four commands;
   a bash test; the grammar mirror test in `test_naming.py`.
4. `_recent_stream`: admit failed notices; a test.
5. `skills/slack/SKILL.md`: document the short forms.
6. `design/trajectory_spec.md`: register `delivery`.

Verification on the box after deploy: send one message to a bare channel id
and one to a bare user id from an identity shell, confirm both land in Slack,
confirm two `delivery` steps with `status: delivered` and a permalink, then
send one to `slack-bogus` and confirm a failed notice and a journal warning.

Delivery 2 (built): `chat sent` over `deliveries.jsonl` (the index file is
named for what it holds, not `sent.jsonl` as first proposed), the prompt
section, `--force` dedup, Telegram notices. Verification on the box: after
the deploy, `chat sent --since 24h` from an identity shell should list the
day's sends with `delivered` beside the Slack ones and the next wake prompt
should carry the "Sent in the last 24h" section (check a `prompt` step).

## Open questions

- Should the ledger's pending threshold be per transport? The Slack bridge
  polls every 0.4 seconds, so a minute is generous; the phone chat has no
  bridge and would always be pending until it writes notices.
- Should a failed notice eventually wake the monolith? Off for now.
