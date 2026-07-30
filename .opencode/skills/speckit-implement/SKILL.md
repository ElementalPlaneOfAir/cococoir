---
name: speckit-implement
description: Execute tasks from a plan in order, verifying each step. Stop and report if a verification fails — never proceed past a broken task.
---

## What I do

I execute the tasks defined in `tasks.md` in dependency order. For each task, I make the code changes, run the verification, and only proceed once it passes.

## When to use me

- After tasks are written
- When the user says "go ahead and build it"
- To resume implementation after a fix

## Prerequisites

- `.specify/specs/<feature-name>/tasks.md` must exist
- Working tree must be clean enough to isolate task changes

## How I work

1. Load tasks.md and build the dependency graph
2. Find the next uncompleted task(s) with all dependencies satisfied
3. For each task:
   a. Read the affected files to understand current state
   b. Make the changes (edit existing files, never create new ones unless the task says to)
   c. Run the verification command specified in the task
   d. If verification fails: stop, report the failure, do NOT proceed to next task
   e. If verification passes: mark task as `[x]` in tasks.md
4. After all tasks complete:
   - Run the full test suite (`nix flake check` for L1, `bash scripts/vmtest-e2e.sh` for L2 if applicable)
   - Update docs/STATUS.md: mark the feature as working with proof (the verification results)
   - Write a summary of what was done and what remains

## Safety rules

- NEVER proceed past a failed verification. Fix the failure first.
- NEVER commit unless the user explicitly asks. Tasks complete does not mean commit.
- If a task's verification requires a VM boot, skip it and note it for the user to run manually.
- If you discover a bug or missing assertion in existing code, add a new task to tasks.md (don't silently fix it inline)
