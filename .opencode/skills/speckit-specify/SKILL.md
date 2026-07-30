---
name: speckit-specify
description: Define what to build — requirements, user stories, and acceptance criteria — before any technical planning. Focus on the what and why, never the how.
---

## What I do

I create a spec document in `.specify/specs/<feature-name>/spec.md` that defines WHAT needs to be built. No implementation details, no Nix code, no module structure — just behavior, contracts, and acceptance criteria.

## When to use me

- Before building any new feature or integration
- When a user describes a feature but hasn't formalized it
- When an existing spec is ambiguous and needs clarification

## Prerequisites

Before writing a spec, I load the constitution and check alignment:
- Read `.specify/memory/constitution.md` (fail if missing)
- Read `docs/STATUS.md` to understand what's broken/blocked
- Read `PLAN.md` for existing ADRs that touch the feature area

## How I work

1. Determine the feature name (slug: lowercase, hyphen-separated)
2. Create `.specify/specs/<feature-name>/` directory
3. Write `spec.md` with these sections:

```markdown
# <Feature Title>

## User stories
- As a <role>, I want <goal> so that <reason>
- ...

## Acceptance criteria
- [ ] <measurable, verifiable condition>
- [ ] ...

## Boundaries
- IN SCOPE: ...
- OUT OF SCOPE: ...
- DEPENDS ON: <existing services, ADRs, flake inputs>

## Non-functional requirements
- Test layers required: L0 | L1 | L2
- Performance / resource constraints
- Security considerations
```

4. Validate: every acceptance criterion must be testable (you can write a bash one-liner or Nix assertion for it)
5. Update `docs/STATUS.md` to note the new spec is in progress

## Anti-patterns

- Do NOT mention specific Nix modules, attribute paths, or implementation code
- Do NOT reference flake inputs by path unless unavoidable for the DEPENDS ON section
- Do NOT write user stories that are really tasks ("As a developer I want to add a function...")
