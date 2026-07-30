---
name: speckit-constitution
description: Create or update the project constitution — governing principles, architecture rules, and development guidelines that constrain all subsequent specs and plans.
---

## What I do

I create or update `.specify/memory/constitution.md` — the project's governing principles. Every spec, plan, and task must conform to this document. It's the root of the spec tree.

## When to use me

- First time setting up the project's spec system
- When the project's architectural rules change
- When a spec or plan violates an unstated principle (codify it here)

## How I work

1. Read the existing AGENTS.md, PLAN.md, and docs/STATUS.md for current context
2. Read `.specify/memory/constitution.md` if it exists
3. Interview the user about principles using these prompts:
   - Architecture constraints (what patterns are mandatory? e.g. factory pattern, service contracts)
   - Testing requirements (what test layers exist? what must every change include?)
   - Code quality standards (naming, file size limits, DRY requirements)
   - Security / operational rules (no secrets in code, idempotent services, etc.)
4. Write or update `.specify/memory/constitution.md` with YAML frontmatter:
```yaml
---
project: cococoir
version: 1
last_updated: <ISO date>
status: reviewed
---
```
5. Cross-check: every principle in AGENTS.md's Architecture Directives must appear here (or be intentionally excluded with a reason)

## Output constraints

- Keep the constitution under 60 lines. Each principle is one line. Details go in PLAN.md.
- No markdown headings below h3. Flat principle list with brief rationale.
- Principles must be verifiable (you can write a tripwire for each one)
