---
name: speckit-implement
description: Execute a proposal's tasks in order, verifying each. Amend the proposal when reality contradicts it. Stop on failure — never proceed past a broken task.
---

## What I do

I execute the task DAG in `.specify/specs/<feature-name>/proposal.md`. Each task: change, verify, mark done. I am the executive branch — I act within the proposal's authority and amend it when reality objects.

## When to use me

- After the user has adjudicated a proposal
- To resume after a fix or a review citation

## Prerequisites

- `proposal.md` exists with tasks and verifications
- Ground truth is green: `bash scripts/status.sh` passes. Never build on a failing tripwire.

## How I work

1. Build the dependency graph; find the next uncompleted task with satisfied deps
2. For each task:
   a. Read the affected files
   b. Make the change (edit existing files; create only what the task names)
   c. Run the task's verification
   d. FAIL → stop, report, do NOT proceed to the next task
   e. PASS → mark `[x]` in proposal.md
3. **Plan amendment.** If reality contradicts the proposal — a file moved, an assumption broke, a better shape appears — STOP. Amend proposal.md first. Future sessions load the proposal as truth; a false proposal poisons them. Then continue.
4. Bugs discovered in existing code become new tasks in proposal.md — never silent inline fixes
5. After all tasks:
   - Run `bash scripts/status.sh` (L1). If anything under `nix/nixos-modules/` changed, also run `bash scripts/vmtest-e2e.sh` (L2)
   - Update STATUS.md: every "works" claim names its proof
   - Hand off to the judiciary: if the change touched a mandatory-review class (new module boundary, nixos-modules, customer-facing config, or any task whose verification needed repair), run `/speckit-review` in a fresh window before calling it done

## Safety rules

- NEVER proceed past a failed verification. Fix first.
- NEVER commit unless the user explicitly asks.
- NEVER review my own work in this window — the judiciary runs cold.
