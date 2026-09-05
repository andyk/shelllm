# tools/

Everything you run around the mind rather than inside it. The mind's own
tools live in [bin/](../bin/).

- `headlong-init` is the one-time bootstrap: interview, first identity,
  first thoughts.
- `identity` creates and manages identities, and `persona` talks to and
  manages an identity by name from anywhere.
- `headlong-web` serves the dashboard, and `headlong-slack-bridge` and
  `headlong-telegram-bridge` connect chat platforms into the mind.
- `shellm-docker-broker` is the host-side policy server for brokered
  Docker. It is never present in the mind's environment.
- `headlong-skills` is the skills package manager (search, install, check,
  init, promote, kernel, remotes). The mind's own `skills` only lists,
  shows, and renders skills, and forwards those subcommands here.
- `responses-ws` is the WebSocket transport for the OpenAI Responses API: a
  `bin/llm` adapter, and a broker that holds one connection across a whole
  shellm run. It is a `uv` script, which is exactly why it lives out here and
  not in `bin/`. See the WebSocket mode section of
  [docs/shellm.md](../docs/shellm.md).
- `shellm-explore` visualizes run trees, `pr-committee` runs multi-model
  PR reviews, and `headlong-killall` stops every Headlong-related process.

The `shellm-*` symlinks are back-compat aliases from the 2026-08-19
rename to `headlong-*` names.
