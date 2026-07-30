# Skill Constitution

Design rationale and change guide for the agent loop (the speckit
system). This is **cold storage**, deliberately excluded from the
session-start load order (AGENTS.md → PLAN.md → docs/STATUS.md) so
the framework stays stable and costs no tokens when it isn't being
changed. Read this only when you intend to modify the loop itself.

- The **law** the loop enforces: `.specify/memory/constitution.md`
- The **process** summary (stations, one section): AGENTS.md § Spec System
- The **why**: this document

## Why the loop exists

The collaboration is one accountable human plus a succession of
amnesiac agents on a token budget. Three facts follow:

1. **Generation is nearly free; verification is scarce.** Producing
   code and prose costs nothing. Knowing what is *true* is what is
   expensive. So executable checks are the primary artifact and
   documents are scaffolding — never the reverse.
2. **Context is bias.** An agent reviewing work from its own window
   defends it, because the window contains the intent, and intent
   explains away mismatches. Dissent therefore has to be structural
   (mandatory in artifacts) and review has to be blind (cold window).
3. **Memory is external, so it must be earned.** Nothing survives a
   session unless it is written down, and anything written down
   rots unless it is either load-bearing or machine-regenerated.

## Design principles

1. **Control loop, not pipeline.** Stations: orient → propose →
   implement → review → converge. The unit of work is the *provable
   move* — a small change with its verification — not the feature.
   Pipelines assume continuity the agents do not have; the loop only
   assumes artifacts.
2. **Dissent is mandatory.** Every proposal and every review states
   its strongest objection. Optional pushback gets skipped exactly
   when it matters; a review that approves without an objection is
   a rubber stamp.
3. **Review runs cold.** The reviewer sees the diff, the acceptance
   criteria, and the law — never the conversation that produced the
   code. If a diff needs a narrator, the diff is incomplete. This is
   blind peer review / red team doctrine implemented with fresh
   context windows.
4. **Status is computed, not narrated.** `scripts/status.sh`
   regenerates the AUTO-STATUS block in docs/STATUS.md from real
   check results. Hand-maintained status is a promise to do forever
   what humans reliably stop doing.
5. **One artifact per change.** `.specify/specs/<name>/proposal.md`
   scales from three lines to a multi-session arc. Fewer files means
   fewer things to keep in sync means less rot.
6. **Amend the proposal when reality contradicts it.** A false
   document is worse than none, because future sessions load it as
   truth. Implementation never just works around a wrong proposal;
   it stops and fixes the proposal first.
7. **North star: cold-start time to first verified change.** If a
   fresh agent cannot make a small proven change using only the
   repo, the memory system is insufficient — that is a bug, filed
   like any other.

## Rejected alternatives

- **Spec-kit style pipeline** (specify → plan → tasks): a document
  waterfall that encodes sequence but not dialogue; the model's
  first draft flows through stations unchallenged. Also: no
  opencode support upstream.
- **External review SaaS** (Greptile et al.): good ubiquity, closed
  source, and the fresh-window skill gets the same effect for the
  price of a context window.
- **Heavy preemptive process**: process built before the failure
  modes are known becomes bureaucracy. This framework is scar
  tissue — every piece exists because a specific failure demanded
  it — and new pieces must be earned the same way.
- **Megadiffs**: large diffs followed by immediate repair commits
  are the signature of generation outrunning verification. Borders
  (small diffs), checkpoints (verification between moves), papers
  (tripwires traveling with the change).

## The machinery

- `.opencode/skills/speckit-*/SKILL.md` — the six stations
  (constitution, orient, propose, implement, review, converge)
- `.opencode/commands/speckit-*.md` — thin slash-command wrappers;
  one per skill, kept in sync
- `.specify/memory/constitution.md` — the law (verifiable principles)
- `scripts/status.sh` — computed status; gates orient and implement
- `docs/STATUS.md` AUTO-STATUS block — regenerated, never hand-edited
- `.specify/specs/<name>/proposal.md` — per-change artifact

## How to change the loop safely

1. Read this document, then `.specify/memory/constitution.md`, then
   AGENTS.md § Spec System. All three before touching any station.
2. Preserve the invariants: dissent mandatory, review cold, status
   computed, three doc layers plus this named exception.
3. Every station change updates both the skill and its command
   wrapper in the same commit.
4. Keep skills small. Every line of process is weight on the
   airplane; a station that needs more than ~60 lines is two stations.
5. Test the framework the way it tests code: run a real change
   through the modified loop before trusting it. The loop's own
   e2e is its first real feature, not its eval.
6. Modify rarely. The framework is infrastructure; instability here
   compounds across every future session. If a change can live in
   a proposal instead of in the loop, put it there.
