# docs/

Reference documentation.

- [install.md](install.md) covers every install variant, including
  non-interactive/CI installs and the long-lived Docker container.
- [shellm.md](shellm.md) is the shellm engine reference: the loop,
  context passing, Docker sandboxing, envs, the `llm` tool, the OpenAI
  Responses protocol and its lifecycle operations (`responses`, background,
  Conversations, compaction, WebSocket mode), and options.
- [RELEASING.md](RELEASING.md) is the playbook for tagging a release on
  GitHub before an announcement: checklist, commands, pinned install line.

The design story and the case for the microharness are in
[philosophy.md](../philosophy.md), and design documents live in
[design/](../design/).
