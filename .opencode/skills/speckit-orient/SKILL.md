---
name: speckit-orient
description: Session start — load the three doc layers, refresh ground truth by running scripts/status.sh, and report what's true, what's broken, and what's next.
---

## What I do

I answer "where are we?" for a cold session. I load the memory layers, regenerate the computed status, and report current reality: failing checks, open proposal tasks, and decisions waiting on the human.

## When to use me

- First thing in every session that will touch code
- After a compaction or context loss
- Whenever the conversation and the repo might disagree

## How I work

1. Read AGENTS.md → PLAN.md → docs/STATUS.md, in that order
2. Run `bash scripts/status.sh` — this regenerates the AUTO-STATUS block in STATUS.md from real check results
3. If any check reports FAIL: that is P0. Report it before anything else. Never start new work on top of a failing tripwire
4. Scan `.specify/specs/*/proposal.md` for open tasks (`[ ]`) and list them with their verifications
5. Report, in this order:
   - **Ground truth**: check results + the Last e2e line
   - **Broken**: STATUS.md landmines, P0s first
   - **In flight**: open proposal tasks
   - **Decision points**: anything waiting on the human (premise questions, alternatives to adjudicate, review verdicts)

## Output constraints

- Under 30 lines of output. Orientation is a map, not a tour.
- Never trust the conversation over the checks. If they disagree, the checks are right and the docs need updating.
- Never declare anything "working" without naming its proof (AGENTS.md § Testing Protocol).
