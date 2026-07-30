---
name: speckit-converge
description: Assess the codebase against spec/plan/tasks and surface drift — what's implemented but not planned, what's planned but not done, what's silently broken.
---

## What I do

I compare the actual state of the codebase against the proposal for a feature, then append any remaining or drifted work as new tasks.

## When to use me

- After a long implementation session
- Before claiming a feature is "done"
- When a previously-working feature breaks and you need to understand the gap
- Periodically, as a health check

## Prerequisites

- `.specify/specs/<feature-name>/proposal.md` must exist

## How I work

1. Load proposal.md and `bash scripts/status.sh` output
2. Check each part of the proposal against reality:
   - **Acceptance criteria**: read the actual code and tests. Which criteria have no evidence of being met? → new tasks
   - **File lists in tasks**: glob for the files. Which don't exist? Which exist but aren't in any task? → new tasks or proposal amendment
   - **Task verifications**: re-run each one. Which fail now? → mark task failed, add a fix task
3. Cross-check the L1 tripwire tests (nix flake check):
   - Are there silent-failure seams (mkForce, optionalAttrs on `config`) in the rendered config? → add assertions
   - Does contract-conformance cover every service module? → add missing entries
4. Append findings to proposal.md:

```markdown
## Converge results — <ISO date>

### Drift detected
- <specific finding>
- ...

### New tasks (appended)
- [ ] T<N>: <title> (from converge)
```

5. Update docs/STATUS.md with drift findings

## Safety rules

- Converge is diagnostic, not prescriptive. Don't change code, only the tasks list.
- If the spec disagrees with reality, flag it for the user — don't silently pick a side
- Broken L1 assertions are P0 (they're the tripwires that should have caught this)
