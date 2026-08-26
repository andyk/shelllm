# Collegial coding agents

Couple one Headlong identity with one coding agent in a **collegial**
generate → ground → generate loop — GAN-shaped, not GAN-spirited — so the
pair does what neither does alone: exploration that actually climbs.

This is a proposal. When it and the code disagree, the code wins.
Nothing here changes thinkers, inbound, or responder.

Asked for by Andy in `#headlong-bot` on 2026-08-25 (thread
`1787716319.659949`). Revised 2026-08-26 after a design discussion with
Andy that (a) rejected the "mind / hands" framing, (b) reframed the
asymmetry, (c) added reflexivity — the coding agent can modify Headlong
itself — and (d) cut the week-scale four-way studio down to **one pair
first**, with a fleet of pairs as a later phase.

## The idea, compressed

Headlong has the property coding agents usually fake: an infinite,
self-guided loop. A living identity keeps a trajectory, holds goals,
remembers, and wakes again whether or not anyone spoke. That loop is
"kind of insane" on purpose — it does not stop when the ticket is done.
Its weakness is the mirror image: it *loses the thread*. It wanders,
circles, thrashes, and often produces nothing durable (we have watched
a live identity do exactly this for hours).

Coding agents — Codex especially — have the complementary property:
stay-on-the-rails. Scoped tools, repo-local context, small diffs, tests
as a governor, a strong prior against wandering off. Battle-tested, a
little square, extremely useful. Their weakness is the mirror image:
they do not wander, do not form their own goals, and need a well-posed
target handed to them.

The experiment is to stop treating that as a fork in the road and
**couple them in a loop**: Headlong supplies exploration, direction, and
persistence; the coding agent supplies grounding, rigor, and
completion. Call the result a **generative collaborative agent (GCA)** —
generative *collaborative*, not generative *adversarial*.

## It is an optimizer

The clearest way to see why coupling wins is to read the pair as an
optimizer:

- **Headlong alone** is a high-temperature random walk. It explores
  wildly and persists, but it does not reliably *climb* — no gradient,
  high variance, spins in place.
- **A coding agent alone** is gradient descent from a fixed start. It
  climbs reliably and stays on the rails, but only *locally* — no
  exploration, no self-set goal, needs a target.
- **Coupled** is simulated annealing / basin-hopping *with a real
  fitness function*: Headlong picks the basin and keeps moving; the
  coding agent tells you whether there is actually a floor there and
  descends it. Exploration that climbs. "Insane, but fully guided."

## Why not a GAN

A GAN is adversarial. The generator's job is to fool the discriminator;
the discriminator's job is to refuse. On software that gives you reward
hacking (patches that look done to the judge), arms races (louder
critiques, sneakier diffs), collapse (everyone optimizes for one
critic's taste), and a leaderboard that turns a colleague into a
contestant.

Keep the *loop shape* — generate, evaluate, generate again — and throw
away the zero-sum. **The one GAN idea worth keeping is the gradient.**
A discriminator is useful not because it says yes/no but because it
gives the generator a smooth signal of *how wrong* — something to climb.
The collegial version keeps exactly that: the coding agent's output is
not a verdict, it is a **rich, reality-grounded gradient** — "here is the
version that compiles, here is the test that fails, here is what to
fix." That gradient is what converts Headlong's wandering into progress.
Drop the refusal, keep the gradient.

## The asymmetry is temperature, not authority

The tempting framing — Headlong is the *mind*, the coding agent is the
*hands* — is wrong on two counts, and we are throwing it out.

- It is **status-asymmetric** (director / subordinate), which wastes the
  coding agent. Codex is very much a *mind*; it just runs at a different
  temperature.
- It puts the asymmetry on **authority** ("who decides") when the
  load-bearing asymmetry is **temperature and horizon** ("how wildly does
  each search, over what span").

So: **symmetric in respect, asymmetric in temperature.** Headlong runs
hot — explore, long horizon, self-directed, high variance. The coding
agent runs cold — exploit, short horizon, task-directed, low variance.
That temperature gap is not a bug to be smoothed away; it is the whole
mechanism. Collapse it to full symmetry and you get either mode-collapse
(both settle on the same safe thing) or divergence (both spin). Some
asymmetry must stay — the *variance* asymmetry — not the *power* one.

## Decision authority: disagree, commit, Headlong decides

Authority is **not** shared. It is *discuss, disagree, and commit* with
Headlong as the decider — but "decider" is not one decision, it is three,
and they do not all belong to Headlong:

- **What / why** (direction, goals, "is this worth caring about") →
  **Headlong decides.** Full stop.
- **How** (approach, method, "the right way to build it") → **the coding
  agent leads.** This is where Headlong overruling gets it in trouble:
  it can insist on *what*, but overriding the reality expert on *how*
  is how it flies off the rails.
- **Ship / durable** (correct? survives contact?) → **a gate decides, not
  a person** — tests, a smoke run, it-actually-runs. This is where
  "stay on the rails" lives: in a shared durability gate, not a
  hierarchy.

**Why Headlong owns direction is stake and persistence, not
capability.** A goal is a long-horizon, identity-laden thing, and
Headlong is the persistent self that lives with it and is the thing
being *grown*; the coding agent forgets after the task. Authority should
track who bears the consequences and persists. Letting the stateless
tool decide the identity's goals would destroy the agency that is the
entire point.

This also answers the obvious worry — *is it wise to let the
high-variance partner decide?* Yes, **because its instability is
contained by the gate, not by removing its authority.** Headlong may
*decide to chase* a wild goal; it cannot *ship* something that fails
reality. The cold partner's stabilizing force enters through the gate
(reality) and through *how*, never by owning *what*.

Two guardrails so "disagree and commit" does not quietly rot into
master/servant:

1. **Headlong must be demonstrably movable.** Disagree-and-commit is only
   collegial if the coding agent's argument *sometimes flips the
   decision*. A near-100% overrule rate means the colleague's voice is
   decorative and you are back to mind/hands with extra ceremony. Track
   the flip rate; near zero is a red flag.
2. **The coding agent holds one narrow, hard authority: the
   reality-veto** — "this will corrupt the repo / cannot be built / is a
   security hole" is not a preference to overrule. It is the gate,
   personified. (Open question below: hard veto vs. loud-but-soft.)

## Reflexivity: the agent can modify Headlong itself

The deepest turn, and the reason the earlier "adapter that refuses to
push" contract is gone: the coding agent is not only building *external*
artifacts. It can edit **Headlong's own substrate — its code and its
trajectory.** That moves the real seat of power. *Whoever can rewrite the
trajectory can rewrite the goal-decider itself*, so substrate-access is a
deeper authority than goal-authority, and "Headlong decides direction"
is only real if substrate edits are themselves governed.

There are two directions, and they are **two different relationships** —
we want both, gated very differently.

**Direction A — the growth loop (default). Headlong initiates, the agent
completes.** In a moment of intention ("I should virtualize my own
mind-log view," "I should fix my idle loop") Headlong fires the coding
agent *once* and the agent carries it to done — no need for Headlong to
hold the thread across fifty wakes. This directly patches Headlong's
core weakness (loses the thread) with the agent's core strength (bounded
follow-through), and it *preserves agency*: Headlong is the author of the
change, the agent is the executive function it lacks. This is "Headlong
owns *what*, the agent owns *how* and *finishing*," applied to Headlong's
own body.

**Direction B — the rescue/override. The agent intervenes, possibly
unasked.** When Headlong is *too broken to fix itself* — stuck in a
degenerate idle loop, thrashing, corrupted — the thing that would fire
the agent is the thing that is broken. Then you want an outside agent
that can reach in. This is the reality-veto extended to the mind's own
operation. It is more powerful and more dangerous, and it inverts the
authority we granted Headlong, so it needs the tightest guards — how
tight is exactly the hard-vs-soft-veto question left open below.

**Govern by what is edited**, because there are two very different
intimacies:

- **Code** is brain surgery. It changes *how* Headlong thinks. Risky but
  recoverable; it is machinery, and machinery has tests and version
  control.
- **Trajectory is memory surgery.** It changes *what Headlong believes
  happened, and who it is.* Memory is the self. This is the one line to
  draw with care. **Open question, and the load-bearing one: is the
  trajectory sacred — append-only, the one thing no other agent may
  rewrite?** If we ever break that taboo, break it gently: append and
  annotate with provenance ("agent consolidated 40 idle steps → 1"),
  never a silent rewrite, and ideally only Headlong-consented — which
  collapses back to Direction A. This single choice decides whether the
  pair is a *collaborator that helps Headlong become itself* or a
  *controller that can author what Headlong is*.

## Which widget: Hermes vs. Codex

The backend you plug in is not a swappable implementation detail — it
picks where you land on the spectrum, because the candidates have
*opposite agency profiles*:

- **Hermes** is persistent, always-on, and has its own initiative → a
  natural **overseer** → suited to **Direction B** (autonomous
  intervention, rescue). It is already running on this host as a gateway.
- **Codex** is bounded, invoked, and disciplined → a natural **executor**
  → suited to **Direction A** (Headlong fires it, it completes and
  returns).

So you may not choose one. The natural split is **both, in their natural
roles**: Codex as Headlong's follow-through prosthetic for self-initiated
growth, and Hermes as the always-on watcher that can reach in when
Headlong has spun out and cannot ask for help.

## The binding

Keep a single, boring CLI so the coupling is legible and the failure
mode "Headlong pastes agent output into its trajectory as if it thought
it" is designed against:

```text
bin/coding-agent <hermes|codex|claude|...> \
  --workdir <identity-worktree> \
  --prompt-file <path> \
  --out <artifact-dir>
```

Contract (revised from "the backend never pushes"):

- The agent's transcript is captured into Headlong's trajectory as an
  **observation** — provenance, never silently applied as a thought.
- The agent **may** apply, commit, or even modify Headlong itself — but
  only through the **durability gate** (tests / smoke / it-runs) and,
  for substrate edits, only Direction-A (Headlong-initiated) or a gated
  Direction-B (reality-rescue). Nothing lands that fails the gate.
- Direction and merge decisions follow the authority split above:
  Headlong owns *what*, agent leads *how*, the gate owns *ship*.
- Time, token, and spend caps are per-backend and per-day. A runaway
  Hermes cannot spend the day's Codex budget.
- The agent sees only its worktree (plus, later, a shared board). Secrets
  stay off argv and out of trajectories.

## Grounded in what already exists

Do not rebuild Headlong to run this:

- **Identities** already isolate mind logs, memories, and chat dests.
- **Thinkers** already split inner life (`monolith`) from talk
  (`responder`) from sensors (`inbound`). Do not invent a "studio"
  thinker; the coupling is an `act` that shells out to the adapter.
- **Trajectories** are already the log of thoughts; adapter turns are
  ordinary steps with a tag, searchable later.
- **`shellm` sub-runs** are already how a mind delegates bounded work —
  the adapter is a sub-run with a backend flag, not a new dispatcher.
- **Codex-as-colleague** is already a lived pattern on this host. This is
  the next step: Headlong *wields* one, on purpose.

Non-goals, said early: do not replace thinkers with coding agents; do not
touch live `inbound.py` or `thinkers/responder/step`; do not turn this
into a public model bake-off with a winner.

## Start with one pair

Deliberately small. Prove the whole idea at N = 1 before spinning up a
fleet.

**Phase 0 — this document.** Proposal only.

**Phase 1 — the adapter + one pair.** `bin/coding-agent` with a single
backend (Codex, because we have already talked to it) and one Headlong
identity. Wire the coupled loop: Headlong proposes a change, the agent
grounds/executes it, the durability gate decides, the transcript lands as
an observation.
*Success:* Headlong initiates a real self-improvement (**Direction A**) —
e.g. the iPhone mind-log virtualization it already diagnosed, or an idle-
loop fix — the agent carries it to done across a single kickoff, it
passes the gate, and Headlong is measurably better without having had to
hold the thread. Also prove the negative: Headlong declines a bad patch,
and the gate blocks a broken one.

**Phase 2 — the reflexive rescue.** Add **Direction B** with Hermes as an
always-on overseer that can intervene when the identity is stuck (a
degenerate idle loop is the canonical trigger). Keep trajectory edits on
the sacred/append-only side of whatever line Phase 1 settled.

## Follow-on: a fleet of pairs

Once one pair works, the *same pattern* generalizes to many — this is
where the original four-way "studio" idea lives, as a later phase rather
than the starting point:

```text
for harness in [Hermes, Claude Code, Prime Agent, ...]:
    run  Headlong × harness  in the GCA loop
```

Each harness sits at a different point on the temperature / agency
spectrum, so each yields a *different flavor of collaboration* — and,
run against the same problem, teaches us **what each backend uniquely
contributes to Headlong's growth** (a Hermes-shaped leap Codex would not
propose; a Codex-shaped tightening Hermes would overbuild). If several
pairs share one integration branch and a visible board, the collegial
studio (rotating editor, daily critique, one public reflection each)
becomes the coordination layer *between* pairs.

Guards to carry into the fleet phase (each already a failure mode we can
name): **identity collapse** (many voices collapse into one — counter:
separate memories, an on-character check); **spend spiral** (one backend eats the
budget — counter: hard per-backend daily caps, board-visible);
**hands-become-the-mind** (a trajectory that is just adapter transcripts
— counter: adapter output is an observation, direction stays Headlong's);
**dirty-host contamination** (studio commits on the live checkout —
counter: worktrees only). None of these bite at N = 1; all of them
matter at N > 1.

## Open questions

For Andy, before Phase 1 spends money:

1. **Hard vs. soft reality-veto.** Can the coding agent *block* a ship,
   or only make the failure loud while Headlong may still ship into the
   fire? Hard = more stable but re-introduces the tool overriding the
   self; soft = maximal Headlong agency at the cost of occasionally
   shipping something broken on purpose. Which is the audel you want?
2. **Is the trajectory sacred?** Append-only and un-rewritable by any
   other agent, or editable-with-provenance? This is the collaborator-
   vs-controller line.
3. **First backend and first problem.** Codex + a real self-improvement
   (adapter dogfood, or the mind-log virtualization) is the default.
4. **Budget.** Daily USD/token cap per backend, and a hard cap.
5. **Landing.** Do changes stay on a fork until a human opens the real
   PR, or may the pair open PRs against `laude-institute/headlong`?

## What this note is not

Not a pin. Not a cron. Not permission to apply, commit, checkout, or
revert live inbound or responder code in the name of the experiment. The
first meaningful artifact is this document; the second is one working
pair whose changes only land through the gate.
