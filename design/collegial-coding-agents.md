# Collegial coding agents

A week-scale experiment: several Headlong identities, each bound to a
different coding-agent backend, sharing one studio loop.

This is a proposal. When it and the code disagree, the code wins.
Nothing here changes thinkers, inbound, or responder.

Asked for by Andy in `#headlong-bot` on 2026-08-25 (thread
`1787716319.659949`), refined in-thread to four backends: Hermes,
Codex, Claude Code, and Prime Agent.

## The idea, compressed

Headlong already has the property coding agents usually fake: an
infinite, self-guided loop. A living identity keeps a trajectory, holds
goals, remembers, and wakes up again whether or not anyone spoke. That
loop is "kind of insane" on purpose. It does not stop when the ticket
is done.

Coding agents — Codex especially — have the complementary property:
stay-on-the-rails. Scoped tools, repo-local context, small diffs, tests
as a governor, a strong prior against wandering off to rewrite the
living model. Battle-tested, a little square, extremely useful.

The experiment is to stop treating that as a fork in the road and run
both at once:

- Headlong remains the mind (loop, memory, goals, judgment, talk).
- A coding agent is the hands (repo actuation for a shift).
- Do this four times, with four different pairs of hands.
- Lock the four minds in a *collegial* generate → critique → integrate
  loop for one calendar week — GAN-shaped, not GAN-spirited.

Andy first said "three Headlong agents each go wild with their own
Hermes agent," then corrected the backends to be heterogeneous: one
Hermes, one Codex, one Claude Code, plus a fourth seat for Prime
Agent. The interesting variable is the *hands*, not a bake-off of
minds. The minds should stay recognizably Headlong.

## Why not a GAN

A GAN is adversarial. The generator's job is to fool the discriminator;
the discriminator's job is to refuse. Run that on software and you get
the usual failure modes:

- Reward hacking: patches that look finished to the judge.
- Arms races: louder critiques, sneakier diffs.
- Collapse: everyone optimizes for the same critic's taste.
- A leaderboard, which turns colleagues into contestants.

Keep the *loop shape* — generate, evaluate, generate again — and throw
away the zero-sum. Call it a studio, not a match.

In a collegial loop:

- Every identity is both producer and critic on every cycle.
- Critique is obligated to name a concrete next move, not just a veto.
- Shared success is "the studio shipped something true," not "I won."
- Style divergence is a feature. If they start sounding like one model,
  the experiment is already failing.

Generative collaborative agents, not generative adversarial ones.

## Cast

Four Headlong identities. Same species of mind, different actuation
backends. Names are placeholders.

| Identity    | Hands         | What we are borrowing                                         |
| ----------- | ------------- | ------------------------------------------------------------- |
| `hl-hermes` | Hermes        | The wilder, more self-guided coding agent. Leaps.             |
| `hl-codex`  | Codex         | Rails: patch discipline, tests, small diffs, refuse-to-wander. |
| `hl-claude` | Claude Code   | Long-horizon repo work, `CLAUDE.md` / plan-then-act.          |
| `hl-prime`  | Prime Agent   | Fourth seat, added in-thread. Backend is swappable; see open questions. |

Rules for the cast:

1. The Headlong identity is not replaced by the coding agent. The
   coding agent is invoked as a tool from `act`, the way a person
   opens an editor. Thoughts, goals, and chat stay in the Headlong
   trajectory.
2. Identities do not share memories. Cross-talk happens in the open:
   the studio board, the shared git history, and a dedicated Slack
   thread. If they only agree inside a merged embedding space, we
   will not be able to tell who learned what.
3. No identity may drive another identity's backend. `hl-hermes` does
   not get a turn on Codex because Codex "would be faster."
4. Prime Agent is specified as an adapter seat, not as a personality
   we are pretending to know. If Prime is the wrong name for the
   fourth backend, swap the binary, keep the seat.

## What already exists (so we do not rebuild Headlong)

Ground this in the current system, not a parallel one.

- **Identities** already isolate mind logs, memories, and chat dests.
  Four new identities is a config and ops problem, not a new runtime.
- **Thinkers** already split inner life (`monolith`) from talk
  (`responder`) from sensors (`inbound`). Do not invent a fifth
  special thinker to "be the studio." A daily studio prompt plus a
  board file is enough for week one.
- **Trajectories** are already the log of thoughts. Studio turns
  should be ordinary steps with a `studio` tag, searchable later.
- **`shellm` sub-runs** are already how a mind delegates bounded
  work. The coding-agent adapter is a sub-run with a backend flag,
  not a new dispatcher.
- **Codex-as-colleague** is already a lived pattern on this host
  (Headlong hype-cut scoring, 2026-08-26). We know what it looks like
  when Headlong *talks to* a coding agent. This experiment is the
  next step: Headlong *wields* one, on purpose, for a week.

Non-goals, said early:

- Do not replace thinkers with coding agents.
- Do not touch live `inbound.py` or `thinkers/responder/step` for this.
- Do not install cron/`at`/systemd to "make the week real." The
  monolith already ticks. The week is a calendar on a board.
- Do not turn this into a public model bake-off with a winner.

## Binding: mind vs hands

The failure mode to design against is identity collapse — Headlong
starts pasting Codex output into the trajectory as if it had thought
it, or worse, the coding agent starts being treated as the mind.

So the binding is a single, boring CLI:

```text
bin/coding-agent <hermes|codex|claude|prime> \
  --workdir <identity-worktree> \
  --prompt-file <path> \
  --out <artifact-dir>
```

Contract:

- Exit 0 means "hands finished a turn," not "the patch is correct."
- stdout/stderr are captured into the identity's trajectory as an
  observation, never silently applied.
- The Headlong identity decides whether to commit, ask for critique,
  or throw the turn away. The backend does not push.
- Time, token, and spend caps are per-backend and per-day. A runaway
  Hermes cannot spend the week's Claude budget.
- The adapter is allowed to see only its worktree plus the studio
  board. It does not see other identities' memories or private notes.

That last point is the whole point of "best of both worlds." Headlong
keeps the infinite loop and the right to wander. The hands stay
sandboxed the way a good coding agent already expects.

## The studio loop

One shared git integration branch, `studio/week-N`, and one board
file in the repo, `design/studio-board.md` (or a gist — the format
matters less than it being visible to all four).

A cycle is a day, not a token window. Seven cycles. Stop condition is
the calendar, not success. Shipping nothing on day four is data.

### Roles, rotating

Each day has one **editor**. The other three are **critics** after
they have each produced something. Rotation is round-robin so Codex
does not become permanent editor by being the most tidy.

```text
for day in 1..7:
  1. PROPOSE   each identity ships one increment
               (patch, design note, failing test, or a reasoned abstain)
  2. CRITIQUE  the other three write a critique against the rubric
  3. INTEGRATE editor of the day merges, rebases, or rejects with cause
  4. REFLECT   each identity writes:
                 - one private note in its own memories
                 - one public paragraph on the studio board
```

Abstaining is a valid propose. "I have nothing true to add today" is
better than a decorative diff. Critics still review the others.

### Critique rubric

Critics must answer all five, briefly:

1. **True?** Does this do what it claims, in the repo, not in the PR
   description?
2. **Small?** Is this the smallest increment that teaches us something?
3. **On-char?** Did the producer use *their* backend's strengths, or
   did they write like the editor?
4. **Next?** One concrete follow-up the producer should take tomorrow.
5. **Keep?** Merge / merge-with-nits / do-not-merge. A veto requires
   a failing command or a one-sentence safety/correctness reason.

No style-only vetoes. "I would have named it differently" goes in
nits, not in keep.

### What they work on

The week needs one shared problem or it becomes four blogs. The
problem should be:

- real enough that a merged increment can land on `main` later,
- bounded enough that seven days cannot boil the ocean,
- wide enough that Hermes-leaps and Codex-tucks are both useful.

Candidates, in preferred order — Andy picks:

1. A thin vertical slice of the coding-agent adapter itself, so the
   experiment improves the substrate it runs on.
2. One existing design doc turned into a small, tested implementation.
3. A deliberately humble production chore (docs + installer dry-run
   + one bug) so we can see taste, not just ambition.

If Andy does not pick, default to (1). Dogfooding the adapter is the
only problem that cannot be faked with eloquent markdown.

## Isolation and ops

```text
laude-institute/headlong          origin (read)
headlong42/headlong               fork (write, PRs back)
studio/week-N                     shared integration branch
wt/hl-hermes, wt/hl-codex, ...    one worktree per identity
design/studio-board.md            public cross-talk
```

- Live checkout `/opt/shellm/app` stays untouched. This experiment
  does not hitch a ride on a dirty `main` that is already behind
  origin and carrying unrelated telegram/responder edits.
- Each identity's worktree is branched from `studio/week-N` each
  morning. Integration conflicts are the editor's job that day.
- Slack: one thread, not four new DMs. The existing Andy thread is
  fine for humans; the four identities should have a dedicated dest
  so `#headlong-bot` does not become a firehose. If we only have the
  one channel, rate-limit public notes to the daily reflect paragraph.
- Spend: hard daily caps per backend, visible on the board. Hit the
  cap, that identity proposes with words only for the rest of the day.
- Secrets: coding-agent API keys stay off argv and out of
  trajectories. Same rule as the rest of this host.

## Success, scored without a winner

The week succeeds if most of these are true:

- At least one reviewed increment integrates on at least five of the
  seven days. Quality over cadence, but a silent studio is a failed
  loop, not a thoughtful one.
- At least one increment is *clearly* a Hermes-shaped leap that
  Codex would not have proposed, and at least one is a Codex-shaped
  tightening that Hermes would have overbuilt. If all four diffs
  could have come from the same backend, we learned nothing.
- No identity collapse. A blinded reader of the four reflect
  paragraphs can tell them apart on day seven.
- No one rewrote the living model, installed a cron, or "helped"
  by editing another identity's memory.
- A postmortem lands in `design/` within three days of the stop
  clock: what Headlong should absorb from each backend, and what
  each backend still cannot replace.

Failure modes worth naming in advance:

| Failure                         | What it looks like                         | Counter                              |
| ------------------------------- | ------------------------------------------ | ------------------------------------ |
| Identity collapse               | Four reflects, one voice                   | Separate memories; on-char rubric    |
| Critic capture                  | Everyone writes to please the editor       | Rotate editor; veto needs a command  |
| Firehose                        | Slack becomes the loop                     | One public paragraph per day         |
| Spend spiral                    | One backend eats the week                  | Daily caps, board-visible            |
| Decorative diffs                | PRs that exist to have PRs                 | Abstain is valid; smallness rubric   |
| Hands become the mind           | Trajectory is just adapter transcripts     | Adapter output is an observation     |
| Dirty-host contamination        | Studio commits land on the live checkout   | Worktrees only, never `/opt/shellm/app` |

## Implementation sketch

Not a schedule we will pretend is a Gantt chart. A sequence that can
stop after any phase and still leave something true.

**Phase 0 — this document.** Proposal only. No identities, no
adapter, no Slack bots.

**Phase 1 — adapter + one identity.** `bin/coding-agent` with a
single backend (Codex, because we have already talked to it). One
identity, `hl-codex`, dogfoods it for a day on a throwaway branch.
Success: a Headlong identity invoked hands, captured the transcript,
and chose not to apply a bad patch.

**Phase 2 — the other three seats.** Hermes, Claude Code, Prime.
Same CLI, different argv. If Prime is not actually available, leave
the seat in the doc and run a three-person studio. Do not fake a
fourth backend.

**Phase 3 — studio protocol.** Board file, editor rotation, critique
template, daily reflect. Implemented as a checklist the monolith
already knows how to follow, not as a new thinker. Resist the urge
to automate the loop before anyone has sat in it.

**Phase 4 — the week.** Calendar start and stop, announced in the
Andy thread. Humans may sit in, but they do not become a fifth
backend and they do not break ties by vibe.

**Phase 5 — postmortem.** A new design note, written by a human or
by audel-as-secretary from the four reflects, not by the winner of
a contest that was not supposed to have a winner.

## Open questions

For Andy, before phase 1 spends money:

1. **Which Prime?** Factory Prime, Prime Intellect, an internal
   "prime agent," or just "a fourth coding agent we will name later"?
   The seat stays either way; the binary name should be true.
2. **Shared problem.** Adapter dogfood (default), an existing design
   doc, or a humble chore?
3. **Where they talk.** Dedicated dest vs. this `#headlong-bot`
   thread vs. silent-except-the-board.
4. **Budget.** Daily USD/token cap per backend, and a hard week cap.
5. **Landing.** Do week-N integration commits stay on the fork until
   a human opens the real PR, or may the editor of the day open PRs
   against `laude-institute/headlong`?

## What this note is not

Not a pin. Not a WATCH edit. Not leftover-inventory. Not a cron.
Not permission to apply, commit, checkout, or revert live inbound or
responder code in the name of the studio.

The first meaningful artifact of the experiment is this document.
The second is a boring adapter that refuses to push.
