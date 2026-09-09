# Collegial coding agents

**In one sentence:** pair two programs that work on code together — one that
dreams up its own ideas but wanders and finishes nothing, and one that is
careful and reliable but has no ideas of its own — so the careful one checks,
finishes, and (when asked) improves the wild one, and real working code gets
made that neither would make alone.

This is a proposal, not built code. If it and the code disagree, the code wins.
Nothing here touches the live message-handling paths (inbound / responder).

*History:* asked for by Andy (2026-08-25); reframed 2026-08-26 around an
optimization-loop idea; rewritten 2026-08-27 into plain language after a
no-jargon review, then merged back with the technical framing so the plain
version carries the reader and the deeper version is there for anyone who wants
it. (Working name: "collegial coding agents.")

## What we are trying to do

Two existing programs, run as a pair:

- **Headlong** — an "identity" that runs on its own, forever. It keeps a diary of
  everything it thinks and does (its *trajectory*), sets its own goals, remembers,
  and wakes itself up even when nobody is talking to it. Its strength: it never
  stops and comes up with its own directions. Its weakness, watched happening
  live: it wanders, repeats itself, and usually produces nothing that lasts — it
  will wake up every ten minutes for hours and get nothing done.
- **A coding agent** — an off-the-shelf tool like Codex or Claude Code. Hand it a
  task and it does it: edits files, runs tests, makes a small change, stops. Its
  strength: it stays on task and actually finishes. Its weakness: it has no goals
  of its own and won't do anything you don't hand it.

The plan is to stop choosing between them and run them as a loop: Headlong comes
up with something to do, the coding agent actually does it and checks whether it
works, and only things that work are kept. The "something to do" can include
improving Headlong itself.

## How it's done today, and why that's not enough

Today these are two separate things. People drive coding agents by hand — a
person picks the task, the agent does it. And Headlong runs on its own but
produces little that lasts. So today you can have *self-directed but useless*, or
*useful but not self-directed* — not both. If you want a program that decides for
itself what to build and then reliably builds it, nothing off the shelf does
that.

## What is new, and why we think it will work

The new part is small and specific: **couple the two in a loop where the reliable
one checks and finishes the self-directed one's ideas — and can also repair the
self-directed one itself.**

The plain reason it should work: each covers the other's exact weakness. Headlong
supplies goals and persistence; the coding agent supplies discipline and a
reality check. Alone, Headlong explores but never lands; alone, the coding agent
lands but never explores. Together: exploration that actually lands.

**The same idea, stated precisely — read the pair as an optimizer.** An optimizer
is anything that searches for a better answer.

- **Headlong alone is a high-temperature random walk.** "Temperature" here is how
  wildly it jumps around; Headlong runs hot. It explores widely and never stops,
  but it does not reliably *climb* toward better — no signal telling it which way
  is up, high variance, spins in place.
- **A coding agent alone is gradient descent from a fixed start.** It follows the
  local slope downhill — climbs reliably and stays on the rails — but only from
  wherever you drop it; no exploration, no goal of its own, needs a target.
- **Coupled, they are simulated annealing with a real fitness function** —
  basin-hopping, in the optimization textbooks: the hot process picks a region
  and keeps moving, the cold process tells you whether there's actually a floor
  there and descends it. A "fitness function" is just a way to score how good an
  answer is; here, reality is the score (does it compile, pass, run). That is the
  whole trick — **exploration that climbs.** "Insane, but fully guided."

## The shape: a collaborative version of a GAN

The loop above has the shape of a GAN (a generative adversarial network): one
part generates, another evaluates, and the feedback makes the generator better.
But a GAN is *adversarial* — the generator's job is to fool the evaluator, the
evaluator's job is to refuse. Run that on software and you get the familiar
failure modes: patches built to look done to the judge, arms races, everyone
converging on one critic's taste, and a leaderboard that turns a colleague into a
contestant.

Keep the loop shape, throw away the zero-sum. **The one idea worth keeping from
the GAN is the gradient.** An evaluator is valuable not because it says yes/no,
but because it gives the generator a smooth signal of *how wrong* — something to
climb. The collaborative version keeps exactly that: the coding agent's output is
not a verdict, it is a rich, reality-grounded signal — "here is the version that
compiles, here is the test that fails, here is what to fix." Drop the refusal,
keep the gradient. Call the result a **generative collaborative agent (GCA)**:
generative *collaborative*, not generative *adversarial*.

(Design note: a pass/fail check is a *binary* signal, but "a rich gradient" is
graded. Those are in tension. The more the coding agent returns *graded* feedback
— how close, what improved, what regressed — rather than a bare pass/fail, the
faster the pair climbs. Start with pass/fail; enrich the signal as we go.)

## The asymmetry is temperature, not rank

It is tempting to call Headlong the "mind" and the coding agent the "hands." That
is wrong, and we are not using it. It makes the coding agent a subordinate (it is
not — Codex is very much a mind), and it puts the difference on *authority* when
the difference that matters is *temperature and horizon*: how wildly each one
searches, and over what span. Headlong runs hot — explore, long horizon,
self-directed, high variance. The coding agent runs cold — exploit, short horizon,
task-directed, low variance.

So: **equal in respect, unequal in temperature.** That gap is not a defect to
smooth away; it is the mechanism. Make them identical and you get one of two
failures — they settle on the same safe answer (collapse), or they both wander
(divergence). Some asymmetry has to stay. It is the *variance* asymmetry, not a
*rank* asymmetry.

## Who cares — what changes if this works

Three concrete things:

1. **Real code ships.** Headlong stops producing diary entries that go nowhere and
   starts producing tested changes that land in the repo. (It already found a real
   bug on its own: the mind-log web page crashes on an iPhone because it draws a
   thousand items at once. With this, it fixes that — and the fix stays fixed.)
2. **Headlong gets better over time,** because it can reliably improve its own code
   and tidy its own memory instead of losing the thread every time it tries.
3. **We learn how to let a program safely improve itself** — its code and its
   memory. That is the real question underneath all of this, and nobody has a
   clean answer.

If none of those happen, the experiment failed — which is also worth knowing.

## Risks, in plain terms

- **It spends too much.** Two agents in a loop burn money. → Hard daily spend cap;
  when it's hit, the pair stops for the day.
- **It damages itself and we can't undo it.** A bad rewrite of its own memory or
  code could lose the identity. → Two rules below keep every change reversible:
  never erase history, and never keep a change that fails a check.
- **The two just start agreeing** (this is "collapse" from above). If the coding
  agent never pushes back and Headlong never changes its mind, you have a rubber
  stamp, not a partner. → Measure how often the coding agent actually changes
  Headlong's decision; near-zero means it's broken.
- **It ships something broken.** → Nothing is kept unless it passes a check
  (tests, or at minimum "it runs").

## How much, and how long

Not open questions — you don't start without a number.

- **Build time:** about one week for the first working pair (Phase 1 below).
- **Spend:** cap ~$30/day for the pair while it runs, hard cap ~$200 for the first
  week. Andy sets the exact figures; the design assumes there *is* a cap and that
  it is enforced, not aspirational.

## How we'll know it worked (the exams)

- **Mid-term (a few days in):** at least one idea Headlong came up with on its own
  gets built by the coding agent, passes a check, and lands — *and* the coding
  agent has changed Headlong's mind on at least one decision (the push-back is
  real, not decorative).
- **Final (end of the first run):** count the real, tested changes that landed
  from Headlong's own ideas; run the ablation — Headlong alone vs. the pair on the
  same task — and show the pair produced more lasting work; and confirm nothing was
  lost: no erased memory, no broken code left behind.
- **The single number to watch is the "changed-its-mind" rate** (the flip rate):
  how often the coding agent's objection actually flips Headlong's decision. It is
  the difference between a partnership and a rubber stamp, and it is easy to
  measure. Treat it as the pair's headline metric, not just a guardrail.

## How it works

Four rules do the work.

**1. Who decides what.** Split each decision by who is the right one to make it —
this follows the temperature/horizon split above:

- *What to work on* (the goal, the direction) → **Headlong decides.** It is the
  one that runs forever and lives with the goal; the coding agent forgets
  everything after each task. Authority should track who bears the consequences
  and persists. Let the thing with no memory pick the goals and you have thrown
  away the point.
- *How to do it* (the approach) → **the coding agent leads.** It is the one that
  knows what actually works in a repo; this is where Headlong overriding it goes
  wrong.
- *Whether it's good enough to keep* → **a check decides, not either program** —
  tests pass, or at least it runs. "Stay on the rails" lives here, in the check,
  not in a chain of command.

Plus one condition: **Headlong has to actually change its mind sometimes.** If it
overrules the coding agent every time, the partnership is fake — which is exactly
what the flip rate measures. And note this is why the volatile partner can safely
hold the goals: its instability is contained by the check, not by taking away its
authority. It may *decide to chase* a wild idea; it cannot *keep* one that fails
reality.

**2. Fixing itself — two cases, guarded differently.** This is the part that makes
the pair more than a task-runner, and the part to be careful with. Whoever can
edit Headlong's own code and memory holds a *deeper* power than whoever picks the
goals — you can rewrite the goal-picker itself — so these edits are governed
tightly.

- *Headlong asks to be changed (the growth loop).* Headlong decides "I should fix
  my own X," hands it to the coding agent once, and the coding agent finishes it.
  This is the normal way Headlong improves, and it fixes its worst habit directly:
  it no longer has to hold a task in its head across fifty wake-ups — it kicks it
  off once and the reliable partner sees it through. Headlong stays the author;
  the coding agent is the follow-through it lacks.
- *The coding agent steps in uninvited (the rescue).* When Headlong is too broken
  to even ask — stuck doing nothing for an hour, looping — a watcher can reach in
  and fix it. This is more powerful and more dangerous (nobody asked, and it
  inverts who's in charge), so it is held to the strictest checks and used only
  for clear breakage.

**3. Never destroy the past.** Headlong's memory is a diary you only ever add to —
you never erase or rewrite an entry. Want a short summary of a hundred boring
entries? Write the summary as a *new* entry that points back at them; the
originals stay. This is the standard way reliable systems keep history (an
append-only log with derived summaries, the way databases keep a write-ahead log
and lineage), and it makes every "memory change" safe: you can always see what
really happened. This settles the hardest question from earlier drafts — "is the
memory sacred?" — with a yes: **add, never rewrite.** It is also the line between
a *collaborator that helps Headlong become itself* and a *controller that can
author what Headlong is*.

**4. How hard the check is depends on how reversible the change is.** A change
that is easy to undo (a sandboxed edit you can roll back) → let it through and
watch; if it's bad, roll it back. A change that is hard to undo or could break
something important → block it until it clearly passes. Same as gating a risky
deploy. This settles the other earlier open question — "can the check block, or
only warn?" — it depends on whether the change can be undone.

## Which coding agent

The two we have behave differently — opposite profiles — and the difference
decides which job each is good for:

- **Codex** — you invoke it, it does one task, it returns. A bounded executor.
  Good for "Headlong asks to be changed": fire it, get the finished result.
- **Hermes** — already runs on this machine on its own, all the time. A persistent
  overseer. Good for "step in uninvited": it is the watcher that can notice
  Headlong is stuck and reach in.

The backend you plug in is not just an implementation detail — because these have
opposite profiles, it changes what kind of pairing you get. So use both, each for
what it is built for.

## Don't rebuild anything

This rides on what already exists:

- Identities already keep separate diaries, memories, and chat destinations.
- The diary already records everything; a coding-agent turn is just another entry,
  tagged so you can find it later.
- Headlong already knows how to hand off bounded work (a "sub-run"); the
  coding-agent call is one of those with a backend flag, not a new system.
- Headlong talking to a coding agent already happens on this machine. This is the
  next step: Headlong *using* one, on purpose.

The one new piece is a small, boring command that runs a coding agent and writes
its transcript into Headlong's diary as a recorded fact — never silently as
Headlong's own thought:

```
coding-agent <codex|hermes|...> --workdir <dir> --task <file> --out <dir>
```

**Non-goals:** don't replace Headlong's thinking with the coding agent; don't
touch the live message-handling code; don't make this a contest with a winner.

## The plan

Small first. Prove it once before doing it four times.

**Phase 1 — one pair, one real improvement (about a week).** Build the command
above with one coding agent (Codex, because we've already used it) and one
Headlong identity. Wire the loop: Headlong proposes, the coding agent builds and
checks, only passing changes land, every step recorded. *Pass the exam:*
Headlong's own idea (say, the iPhone mind-log fix it already found) gets built,
passes a check, and lands — and Headlong also declined a bad change while the
check blocked a broken one.

**Phase 2 — the uninvited fix.** Add Hermes as the watcher that can step in when
Headlong is stuck, held to the strictest checks and the never-erase rule.

**Later — a fleet of pairs.** Once one pair works, the same setup generalizes:
run `Headlong × <each other coding agent>` and see what each is good at — which
one leaps, which one tidies. Each backend sits at a different temperature, so each
gives a different flavor of collaboration, and running several against the same
problem teaches us what each uniquely contributes. That is where the earlier "four
agents at once" idea belongs — and where the guards for it live: keep their
memories separate so they don't collapse into one voice, cap each backend's spend
so one can't eat the budget, keep every change on a worktree so nothing lands on
the live checkout. None of those bite with one pair; all of them matter with many.
Do it after one works, not before.

## What this is not

Not a background job that runs itself before anyone has watched it work. Not
permission to touch the live message-handling code. Not a contest. The first real
thing this produces is one working pair whose changes only land after they pass a
check.
