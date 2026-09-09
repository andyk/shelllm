# skills/

Skills that ship with the repo. A skill is a directory with a `SKILL.md`
that teaches the agent a procedure for a specialized task, e.g. using
chat or doing web research. The `skills` tool in
[bin/](../bin/) lists and loads them, and the
[skill-author](skill-author/SKILL.md) skill explains how to write a new
one.

An agent's own learned skills are data and live in its `.skills/`
directory, which is gitignored.

## Operating this framework

- [operating-headlong](operating-headlong/SKILL.md) — choose between a
  completion, shellm run, and persistent identity; operate chat, memory,
  trajectory, context, skills, and dispatcher state safely.
- [operating-headlong-responses](operating-headlong-responses/SKILL.md) —
  typed completion workers, background recovery, Conversations, compaction,
  WebSocket transport, and unknown-outcome handling.
- [shellm](shellm/SKILL.md) — compatibility entry for the older skill name;
  distinguishes the execution engine from the Headlong framework.

The installer copies these alongside other bundled skills. Inside an identity,
use `skills show operating-headlong` or `skills show operating-headlong-responses`.
Coding agents discover the same source through `.agents/skills/` symlinks;
edit the originals here, not a second copy. Human guides and runnable examples
are in [docs/operating-headlong.md](../docs/operating-headlong.md) and
[docs/responses-guide.md](../docs/responses-guide.md).
