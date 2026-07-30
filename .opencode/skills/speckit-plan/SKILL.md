---
name: speckit-plan
description: Create a technical implementation plan from a spec — choose modules, define file structure, identify test layers, and surface risks before writing code.
---

## What I do

I create `.specify/specs/<feature-name>/plan.md` — the technical bridge between a spec (what) and tasks (how). This is where Nix module structure, file naming, and test strategy get decided.

## When to use me

- After a spec is written and reviewed
- Before generating tasks or writing any code
- When the user wants to discuss architecture for a spec

## Prerequisites

- `.specify/specs/<feature-name>/spec.md` must exist
- Read the constitution, PLAN.md (for ADRs), and docs/STATUS.md

## How I work

1. Load the corresponding spec
2. Identify which existing modules are affected (read those files)
3. Design the implementation:

```markdown
# Plan: <Feature Title>

## Affected modules
- `nix/nixos-modules/services/<name>.nix` — <what changes>
- (list any file that will be touched)

## New files
- `<path>` — <purpose>

## Architecture decisions
- ADR-NNN if applicable, or propose a new one

## Test strategy
- L0: <Go unit tests if any>
- L1: <eval checks to add to flake checks>
- L2: <vmtest-bootstrap.sh assertions to add>

## Risks
- <what could go wrong at boot time, eval time, or integration boundaries>
```

4. Cross-check against the constitution:
   - Does the plan use the factory pattern where applicable?
   - Are new customer-facing options avoided unless justified?
   - Does the test strategy cover the tripwire protocol?
5. If the plan violates a principle, flag it explicitly with a reason

## Output constraints

- Keep the plan under 80 lines. It's a map, not the journey.
- File paths must be real (check they resolve before writing). Use `src:<line>` references.
- Every risk must have a mitigation (a test or assertion)
