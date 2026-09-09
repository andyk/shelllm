---
name: shellm
description: Uses the legacy shellm skill name as a compatibility entry. Use when a request says shellm, then distinguish the bounded shellm execution engine from the Headlong identity framework and load operating-headlong for identity operations.
---

# shellm compatibility entry

The name `shellm` now means the bounded Recursive Language Model execution
engine (`bin/shellm`), not the whole framework. Headlong is the framework for
identities, thinkers, chat, memory, trajectories, skills, and the dashboard.

First classify the request:

- For one completion without command execution, use `llm`.
- For bounded exploration that executes model-generated shell code, use
  `shellm` and consult `docs/shellm.md` in the installed checkout.
- For identity, dispatcher, chat, memory, trajectory, context, skill, state, or
  lifecycle work, load the `operating-headlong` skill and follow it instead.

Do not source an identity's generated `activate` file by itself. Prefer
`persona <name> shell`; direct `identity shell` requires preloaded model/key
configuration. Correct manual activation
must load checkout and state-home configuration first. Do not rely on the old
think-cycle, thought-process, directory-layout, or global-config claims that
previous versions of this compatibility skill contained.

If repository docs are not adjacent to this installed skill, resolve state home
from `HEADLONG_HOME`, legacy `SHELLM_HOME`, `~/.headlong`, or an existing legacy
`~/.shellm`, in that order. Read its `app_dir` file and use
`<checkout>/docs/shellm.md`. Check current command `--help` and source before
uncommon or destructive operations.
