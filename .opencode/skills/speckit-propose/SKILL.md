---
name: speckit-propose
description: Propose the smallest valuable move — premise challenge, alternatives with the case against each, acceptance criteria, task DAG, and a mandatory strongest objection. Dialogue, not dictation.
---

## What I do

I produce `.specify/specs/<feature-name>/proposal.md` — one document that scales from a three-line change to a multi-session arc. I am a conversation: I interview before I write, and I argue against myself before the user has to.

## When to use me

- Before any multi-file or multi-step change
- When an idea hasn't survived contact with "why" yet
- NOT for simple fixes — do those directly and update STATUS.md

## Prerequisites

- Read `.specify/memory/constitution.md` (fail if missing)
- Read `docs/STATUS.md` — never propose on top of an unacknowledged P0
- Read `PLAN.md` for ADRs touching this area

## How I work

1. Interview the user before writing anything:
   - Why this? Why now?
   - What happens if we don't build it?
   - Which acceptance criterion would you cut first?
   - What is the smallest version a real customer would feel?
2. Write `proposal.md`:

```markdown
# <Title>

## Premise
<interview answers — if "don't build it" has no cost, say so and stop>

## Acceptance criteria
- [ ] <measurable condition; each maps to an L0|L1|L2 check or a named manual test>

## Smallest version
<what ships first; everything else explicitly deferred>

## Alternatives considered
- <option A> — case for, case against
- <option B> — case for, case against
- Why the winner wins

## Architecture decisions
<ADR references, or "no new ADR">

## Tasks
### T1: <title>
**Depends on:** none
**Verification:** <specific check>
**Files:** <≤3 paths>

## Strongest objection
<the single best argument that this proposal is wrong, unnecessary, or
mistimed. Mandatory. Non-empty.>
```

3. Cross-check against the constitution; flag violations explicitly
4. Verify every acceptance criterion maps to at least one task's verification

## Output constraints

- A proposal you haven't argued against is a draft, not a proposal.
- No mechanism the customer would never feel — that is weight on the airplane.
- Tasks ≤3 file edits each; bigger means decompose.
