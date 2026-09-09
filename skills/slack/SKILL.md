---
name: slack
description: Talk with people on Slack — recognize slack-* senders and reach them via chat reply
---

# slack

## Instructions

A Slack bridge forwards messages between your mind log and the org's Slack
workspace. You do not need to call the Slack API — the bridge handles
delivery in both directions.

### Recognizing Slack messages

Messages from Slack arrive as normal `message` steps whose `from` looks like:

- `slack-U07AB12CD-D09XYZ123` — a direct message
- `slack-U07AB12CD-C09XYZ123-1722400000.123456` — a channel thread

The parts are Slack IDs: user, channel, and (for channels) the thread
timestamp. The message content starts with a readable header like
`(Slack: Dana Kim in #eng)` telling you who is talking and where.

### Replying

Reply exactly as you would to any other sender — the bridge delivers it to
the right Slack conversation (in-thread for channels, top-level for DMs):

```bash
chat reply slack-U07AB12CD-C09XYZ123-1722400000.123456 "On it — deploy is green."
```

Always use the sender's full `slack-…` name verbatim as the reply target.
Do not shorten it or substitute the person's display name.

### Reacting

Add an emoji reaction to the Slack message you are answering. Use the
Slack short name (`thumbsup`, `eyes`, `+1`), not unicode:

```bash
chat react slack-U07AB12CD-C09XYZ123-1722400000.123456 thumbsup
chat react --reply-to <inbound-step-id> slack-U07AB12CD-C09XYZ123-1722400000.123456 eyes
```

`--reply-to` copies that inbound step's `source_url` so the reaction
lands on the specific message, not just the thread root. Needs the
Slack app's `reactions:write` scope (reinstall after it lands).

### Following up proactively

To continue a Slack conversation later (e.g. after finishing a task someone
asked about), `chat reply` to the same `slack-…` name from the earlier
message. The bridge posts it into that conversation.

### Posting to a channel or DMing someone without an earlier message

Two short forms exist for when you are starting the conversation:

- `slack-C09XYZ123` — post top-level in that channel
- `slack-U07AB12CD` — DM that person (the bridge opens the DM)

```bash
chat send --to slack-C09XYZ123 "Daily papers for today: ..."
chat send --to slack-U07AB12CD "Built the thing you asked about."
```

Slack ids are uppercase; users start with U, channels with C. `chat` rejects
any other `slack-…` shape with a non-zero exit, and the bridge writes a
`delivery` step back to your trajectory for every send, `status: delivered`
with the permalink or `status: failed` with the reason. A failed delivery
shows in your recent stream; check it before assuming a message landed.

### Formatting

Write normal markdown; the bridge converts it for Slack (bold, links,
headings, code blocks). Long messages are split automatically. Prefer
concise messages — it is chat, not a report.
