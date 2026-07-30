---
name: speckit-tasks
description: Break a plan into ordered, dependency-aware implementation tasks. Each task is a single logical change with verification.
---

## What I do

I create `.specify/specs/<feature-name>/tasks.md` — an ordered task list derived from the plan. Each task is one logical change, has clear acceptance criteria, and knows what must be done before it.

## When to use me

- After a plan is written and reviewed
- Before starting implementation
- After `/speckit.converge` adds new tasks

## Prerequisites

- `.specify/specs/<feature-name>/plan.md` must exist
- Read the corresponding spec.md for acceptance criteria mapping

## How I work

1. Load plan.md — each "Affected module" and "New file" entry becomes at least one task
2. Generate tasks in order. Each task is:

```markdown
### T<N>: <brief title>
**Depends on:** T<X>, T<Y> | none
**Verification:** <specific L0|L1|L2 check or manual test>
**Files:** <comma-separated paths>

<1-3 sentence description of the change>
```

3. Task ordering rules:
   - API/factory changes before consumers
   - Test tripwires in the same task as the code they protect (per AGENTS.md Testing Protocol)
   - Non-breaking changes before migrations
   - Nix module changes before vmtest composition changes
4. After writing, verify: every acceptance criterion from spec.md maps to at least one task's verification
5. Update docs/STATUS.md with the new feature in the "Current focus" section

## Output constraints

- Tasks.txt format (git-commit-message style): imperative mood, lowercase, no period
- No task should take more than ~3 file edits. If it does, it needs decomposition
- Dependency graph must be a DAG (no cycles). If there's a cycle, the plan is flawed — go back.
