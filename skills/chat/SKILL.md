---
name: chat
description: Reply to humans who are chatting with me
metadata:
  shellm:
    requires:
      bins: ["chat"]
---

# chat — Talking to humans

I can talk to humans and other AIs. I send and receive messages by way of my trajectory. Each message is a step in my trajectory.

There is a CLI tool called `chat` that is used for me and others to send messages. Others can use `chat send <message>` to append chat messages to my trajectory. To send a message to others, I can write steps directly to my trajectory or I can use `chat reply <to_name> <message>`.

## Trajectory step types

A step in my trajectory with `"type":"message"` is a message to or from me. I know who it is from and to by looking at the step's `to` and `from` fields.

A `message` in my trajectory `to` me, i.e. my name, is someone talking to me.
A `message` in my trajectory `from` me, i.e. my name, is something I already said.

## Replying to humans

To send a reply, I can use `chat reply <to_name>`:

    chat reply <to_name> <message>

This creates a `message` step with `from` set to my name and `to` set to the recipient.

IMPORTANT: if I use `chat send` it sends a message to myself, so I must NEVER use `chat send` to reply to somebody else. I always use `chat reply`.

## Reviewing conversation history

    chat history [N]                          # show last N messages (default 20)
    chat history --with <name> [--since 7d]   # my whole conversation with one person
    chat history --with <name> -n 50 --json   # same, as JSON with timestamps
    chat pending                              # requests the responder deferred to me that I have not delivered yet
    chat sent [--since 24h] [-n N] [--json]  # what I sent, newest first, with what the bridge reported back

`--with` groups a person across every name a bridge has used for them (a
Slack user's DM and every channel thread, a phone chat name), so it is the
way to check what someone and I said before, even days ago. It reads a
small index next to my trajectory, so it is fast; `chat person-key <name>`
shows the stable key behind a routing name.

## Knowing what I already sent

`chat sent` is my sent folder. Each line is one outbound message with its
delivery state: `delivered`, `failed (reason)` when the bridge could not
post it, `pending` when a Slack or Telegram bridge has not confirmed it
yet, or `unconfirmed` for a transport that never reports back (the phone
chat). My wake prompt shows the last day of it. A `failed` line means the
person never saw the message; fix the address and send again. `chat send`
and a proactive `chat reply` refuse an exact repeat of something I sent to
the same destination in the last 24 hours; `--force` overrides that when
the repeat is deliberate.

## When to reply

I should reply when I see a `message` that seems directed at me or asks me a question. I keep my replies natural and conversational. I can also start a conversation if I have a reason to talk to the person, such as asking for help or sharing something relevant to them.

## Message formatting

Plain text is the only format guaranteed to render correctly in every chat client, so I default to it:

- First sentence carries the whole point. Treat it as a subject line.
- No markdown: no backticks around identifiers, no `**bold**`, no `*italics*`, no `[text](url)`. Use plain names, put single quotes around phrases if I need emphasis.
- Long context (paths, patch names, diffs, log excerpts) goes after the lede, never in it.
- If I've sent more than 2 messages in a burst without a reply, the next update belongs in my running note (mem edit), not another chat message. I re-raise in chat when the person re-engages.

### Shellm.app (macOS menu-bar client)

If the person I'm talking to reads chat through Shellm.app (macos/Shellm/main.swift), two rendering facts apply on top of the rules above:

1. Notifications truncate the message to 200 chars. Anything past ~180 chars is invisible until they open the popover, so keep the lede under that.
2. The message body renders as plain SwiftUI `Text` with no markdown parsing. Backticks, asterisks, and square-bracket links render literally.
