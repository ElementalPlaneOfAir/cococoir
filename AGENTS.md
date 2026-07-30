# Global Directives

- Be very honest. Tell me something I need to hear even if I don't want to hear it.
- Be proactive and flag issues before they become problems.
- Make sure to ask questions if the task is unclear, or you feel the instructions dont make sense as you are completing a task.
- "Perfection is not achieved when there is nothing left to add, it is achieved when there is nothing left to remove."
- **Customer-facing config stays under 50 lines total.** Every new option that requires the customer to set it is a design failure. Before adding a customer-facing option, exhaust these alternatives:
  1. Make it default to the right value.
  2. Auto-derive it from another option the customer already sets.
  3. Auto-wire it from sops-nix secrets (with `lib.optionalAttrs` on `cococoir.secrets.sopsFile` — see the cycle note below).
  4. Make the service always-on if the platform requires it.
  If none of those work, expose the option — but flag the cost.
- **Don't foist integration complexity on the customer.** "jellyfin + jellarr" is one thing from the customer's perspective. If they enable jellyfin, jellarr runs. Same for "jellyfin + OIDC integration with dex" — one toggle. Exposing a separate `cococoir.integrations.X.enable` toggle is a code smell; the integration should be auto-activated by the service it pairs with.
- **Module-system cycle note:** any module whose `config` block reads `config.cococoir.secrets.sopsFile` (or any other path in `config` that gates a contribution to the same module) creates an infinite recursion. The NixOS module system can't break this. Workarounds:
  - Move the gate to a different module (sibling, not child) and use `lib.optionalAttrs` — this is what the (currently-failed) `secrets-auto-wire.nix` attempted.
  - Use `config ? <attrset>.<key>` to check existence without reading the value. Tested: also recurses for paths inside `config`.
  - Have the customer set the option explicitly, in their config, gated on a non-`config` read.
  If the cycle blocks an integration, prefer the customer-wires-explicitly path over a fragile workaround. A 10-line boilerplate the customer writes once is better than a 200-line auto-wirer that might break on a nixpkgs upgrade.



# Context System

Docs rot when living state is written in stable docs, and agent sessions lose the plot when there is no defined load order. This project keeps exactly three layers:

- **AGENTS.md** — how to work here (process, style, protocols). Changes rarely.
- **PLAN.md** — what we're building and why; ADRs live here. Changes on decisions.
- **docs/STATUS.md** — where we are *right now*: what works (with proof), what's broken, current focus. Changes constantly.

Session start (every agent, every session): read AGENTS.md → PLAN.md → docs/STATUS.md, in that order — or run `/speckit-orient`, which does this and refreshes the AUTO-STATUS block.

Session end duties:

- If you changed what works or broke something, update `docs/STATUS.md` **in the same commit**. A "works" claim must name its proof (an L1 check name or an e2e run); claims without proof are debt.
- If you fix a bug, add its tripwire (L1 assertion or `scripts/vmtest-bootstrap.sh` check) in the same commit, so the bug cannot silently return.
- Facts live in exactly one place: process here, decisions in PLAN.md, current state in docs/STATUS.md, per-line rationale in code comments. Link, don't copy.
- Do not add new top-level docs. Three layers plus code comments is the whole system. The one sanctioned exception is `SKILL-CONSTITUTION.md`: cold storage for the agent loop's design rationale, read only when modifying the loop itself.

# Spec System

The spec system is a control loop, not a pipeline. Stations:

```
/speckit-orient    → load memory, refresh ground truth (scripts/status.sh), report what's true and what's next
/speckit-propose   → smallest move: premise challenge, alternatives + case against each, mandatory strongest objection
/speckit-implement → execute the task DAG with per-task verification; amend the proposal when reality contradicts it
/speckit-review    → blind judiciary: a cold window sees only the diff, the criteria, and the law; verdict + citations + strongest objection
/speckit-converge  → re-run verifications, surface drift between code and proposal
```

Law lives at `.specify/memory/constitution.md`. Artifacts live at `.specify/specs/<feature-name>/proposal.md` — one document per change, scaling from three lines to a full multi-session arc. Skills are defined in `.opencode/skills/speckit-*/SKILL.md` and loaded on-demand.

North star: cold-start time to first verified change. If a fresh agent can't make a small proven change using only the repo, the docs are insufficient — file that as a bug in the memory system.

Simple fixes skip the loop: do them, update STATUS.md, done.

The loop's design rationale and change guide live in `SKILL-CONSTITUTION.md`. It is deliberately outside the load order — read it before modifying any speckit machinery, and only then.

# Code Architecture Directives

- Write and architect code with a **Zero technical debt** policy. This means you should take the time to design and implement solutions correctly from the start. And if you see a feature that is designed badly, fix and rearchitect it as soon as possible, before building anything else on top of it.
- Every line code that you write makes the project harder to maintain. Whenever you are adding a new feature, consider if you are duplicating functionality. If you are, you MUST refactor the code into a common interface. You MUST create DRY (Don't Repeat Yourself), Reusable, and Flexible code implementations, interfaces, and boundaries.  Otherwise, if possible, always try to modify existing code instead of adding new modules. Furthermore, be aggressive about removing unused or dead code using git commits to make it easily revertible. **ADDING LINES OF CODE IS LIKE ADDING WEIGHT TO AN AIRPLANE, YOU CAN DO IT BUT IT BETTER BE WORTH IT**

# Code Style Directives

- Assertions detect programmer errors. Unlike operating errors, which are expected and handled, assertions are for detecting errors in the logic of your program. The only correct way to handle corrupt/illogical code is to crash. Assertions downgrade catastrophic correctness bugs into liveness bugs. As such try and make sure the average function has a minimum of two assertions. If you encounter a codebase without them, add them in where it makes sense.

- Avoid comments whenever possible as they are often a sign of unclear code. Your goal should be to write code where anyone skim-reading it gets a clear understanding of what it's doing. Always use extremely clear variable names, and use simple control flow to make your code easier to understand.

- Use assertions as documentation. Assertions are supposed to give anyone reading your code an idea of what the expected behavior is, as well as the possible ways that it can fail. Always try to write code like this:

```tsx
function clamp(input: number, low: number, high: number): number {
  if (low > high) {
    throw new Error("clamp requires low <= high");
  }

  const clampedValue = input < low ? low : input > high ? high : input;

  if (clampedValue < low) {
    throw new Error("clamped value must not fall below low");
  }

  if (clampedValue > high) {
    throw new Error("clamped value must not exceed high");
  }

  return clampedValue;
}
```

and never like this:

```tsx
function clamp(x: number, lo: number, hi: number): number {
  // This function clamps the input x between the values
  // lo : represents the low value
  // hi : represents the high value

  return x < lo ? lo : x > hi ? hi : x;

  // Returns the clamped value
}
```

- Tests are very important, and act as a force multiplier on top of assertions. Running extensive tests with your assertions drastically decreases the likelihood of assertions causing problems in production. And every test you run instead of just checking that the output matches, is testing for correctness 10-100 times inside the codebase itself. Do not forget to write them after you have finished writing or updating them after you have finished writing the main code body.

- **When writing React code, follow the guidelines in `spec/REACT_GUIDELINES.md`.** This covers best practices for component design, preventing useEffect misuse, testing, and architecture.

# Testing Protocol

- **Never declare a change "working" from evaluation alone.** `nix eval` succeeding proves the option tree is well-formed; it says nothing about boot-time behavior. The OIDC integration regressed for exactly this reason — it was verified by hand on a long-lived VM, then broke silently on the next fresh boot.
- Test layers (see `nix/tests/default.nix`):
  - L0: Go unit tests (`go test` via flake checks).
  - L1: pure eval checks (`nix flake check`) — includes `vmtest-wiring`, which asserts the *real* vmtest composition keeps the OIDC integration wired (plugins, branding, boot activation). Add an assertion there whenever you add cross-module wiring.
  - L2: `scripts/vmtest-e2e.sh` — nukes `vmtest.qcow2`, rebuilds, boots headless, and asserts the running system (services active, jellarr applied its config, Dex discovery responds, the "Sign in with Dex" button renders). Run it before claiming any change under `nix/nixos-modules/` works.
- **Silent-failure seams are bugs.** Never gate an integration on `options.services ? X` or override a submodule with `lib.mkForce` without an L1 assertion that the integration is present in the rendered config. If a config can be dropped silently, add the tripwire in the same commit.
- When you fix a boot-time bug, add the corresponding assertion to `scripts/vmtest-bootstrap.sh` so the e2e script catches its regression.

# Git Commit Directives

- **NEVER add `Co-Authored-By` trailers.** No exceptions.
- Commit messages should be short, lowercase, and use conventional commit format: `type(scope): description`
  - Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `polish`
  - Scope is optional but preferred (e.g., `feat(cards): add hermit implementation`)
- One logical change per commit. Don't bundle unrelated changes.
- No body text unless genuinely necessary. The subject line should be self-explanatory.
- When squash-merging a PR, the individual commits become the body — so keep each commit message clean and readable as a bullet point.

