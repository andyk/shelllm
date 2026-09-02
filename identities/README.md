# identities/

Identity assets that ship with the repo. Right now that is
[starter-persona.md](starter-persona.md), the template `headlong-init`
uses to draft a new agent's core identity prompt from the install
interview.

Runtime identities (an agent's persona, trajectories, memories, and
activate script) are data, not code. They live in `.identities/`, which
is gitignored.

[operating-constraints.md](operating-constraints.md) is a reviewable
record of operating constraints. Runtime copies are managed separately.
