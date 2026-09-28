# .cursor/rules

**These are pointers, not content.** As of 2026-07-24 the canonical agent context
lives in `.claude/` (Claude Code is the Build lane — see `spend-lanes.mdc`). Files
here exist so Cursor still gets the invariants and knows where to read the depth.

**When a rule needs updating, edit the `.claude/` file — not this directory.**

## What's here

| File | `alwaysApply` | Points to |
|---|---|---|
| `engineering-discipline.mdc` | ✅ | `.claude/skills/t2000-engineering/` |
| `spend-lanes.mdc` | ✅ | — (this is the routing rule itself) |
| `env-validation-gate.mdc` | ✅ | `.claude/skills/t2000-env-gate/` |
| `financial-amounts.mdc` | ✅ | `.claude/skills/t2000-financial-amounts/` |
| `design-system.mdc` | glob: `design-tokens/**`, `apps/**` | `.claude/skills/t2000-design-system/` |
| `sui-platform.mdc` | glob: `packages/sdk/**`, `apps/gateway/**`, `contracts/**` | `.claude/skills/t2000-sui-platform/` |

`engineering-discipline.mdc` is the **one deliberate duplication**: it mirrors the
short always-on block from `CLAUDE.md § Engineering Discipline`, because Cursor does
not read `CLAUDE.md`. Those two copies must stay in sync. Everything else is a
pointer with no duplicated body.

## The 2026-07-24 migration

Before: 21 `.mdc` files, 7 of them `alwaysApply: true` — **none of which Claude Code
could read**, since it has no `.mdc` loader and no `alwaysApply` mechanism.

Changes:
- **10 rules deleted** — all described the retired `@t2000/engine`, BlockVision, the
  removed DeFi surface, or metrics tables (`TurnMetrics`, `SessionUsage`) that don't
  exist anywhere in t2000 source. Git history is the archive:
  `git log --all -- .cursor/rules/<name>.mdc`. They were demoted to
  `alwaysApply: false` one commit earlier (S.806) rather than removed — that
  half-measure is what left them being half-read for months.
- **4 always-apply behavioral rules merged** (`engineering-principles` +
  `goal-driven-execution` + `coding-discipline` + `product-build-algorithm`) into
  one skill plus the always-on block above.
- **`token-data-architecture` folded into** `financial-amounts` (same subject).
- **`geist-ds` → `design-system`**, **`sui-address-balances-and-gasless` →
  `sui-platform`** (renamed to match their skills).

The old "Always-applied" table in this README was also wrong — it listed five rules
as always-applied whose own frontmatter said `alwaysApply: false`, and omitted two
that were `true`. Don't reintroduce a hand-maintained table that can disagree with
the frontmatter; keep the table above honest against the actual files.

## Where everything lives now

| Layer | File | Loaded |
|---|---|---|
| Always-on context | `CLAUDE.md` | every turn |
| Subsystem depth | `.claude/skills/*/SKILL.md` | on task match |
| Per-package notes | `.claude/rules/*.md` | project instructions |
| Rituals | `.claude/commands/*.md` | on `/command` |
| Cursor bridge | `.cursor/rules/*.mdc` | Cursor only |

## Skills are NOT mirrored here

`t2000-skills/skills/<name>/SKILL.md` is the canonical source for the user-facing
product skills (setup, connect, check-balance, receive, send, swap, pay, services,
job, …). Those are **consumer** playbooks; `.claude/skills/` are **contributor**
engineering constraints — different altitude, different audience. Don't merge them.
Skills are **not** a tool inventory — Connect `tools/list` is the SSOT for verbs.

Product skills reach end users via:
1. **`t2000-afi/t2000-skills`** — auto-synced via `.github/workflows/sync-skills.yml`
   (`npx skills add t2000-afi/t2000-skills`).
2. Optional console/skill markdown feeds — **not** per-skill MCP prompts on Connect
   (Connect itself is tools + OAuth only; no `skill-<name>` prompt registry).
