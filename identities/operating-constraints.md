# Operating constraints (shipped notes)

Runtime identity goals live in `.identities/<name>/goals.md` and are
gitignored. This file is the reviewable copy of constraints we want on
the record in git.

## GitHub ops

On first failure or surprise (auth, permissions, wrong account, 403):
stop. One question in the originating thread. No second GitHub attempt.
Don't retry, switch account, fork around, or "I'll just make it work."

Source: Andy in #headlong-bot, 2026-08 (thread
`slack-U0614H65RN3-C0BMVH6LM4K-1787508187.726149`). Historical fail:
kept retrying after the ask.
