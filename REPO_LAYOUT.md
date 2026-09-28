# t2000 Repo Layout

> **Single source of truth for "where does X go?" in this monorepo.**

This is the public-facing layout reference.

## Top-level structure

```
t2000/
├── README.md, LICENSE, CLAUDE.md           ← entry points
├── PRODUCT.md                               ← the product map (2 products · customers · paths in)
├── ARCHITECTURE.md                          ← system architecture
├── REPO_LAYOUT.md                           ← this file (contributor "where does X go?")
├── SECURITY.md                              ← disclosure policy
├── apps/                                    ← deployable apps
│   └── docs/                                (docs.t2000.ai — Mintlify docs site)
│       (marketplace UI + Connect host deploy from the audric monorepo → t2000.ai / mcp.t2000.ai)
├── packages/                                ← npm packages (6 published, lockstep versions)
│   ├── cli/                                 (@t2000/cli)
│   ├── discovery/                           (@t2000/discovery — x402 endpoint probe)
│   ├── id/                                  (@t2000/id — agent_id::registry client)
│   ├── sdk/                                 (@t2000/sdk)
│   ├── serve/                               (@t2000/serve — merchant-side x402 router)
│   └── x402/                                (@t2000/sui-x402 — the x402 dialect for Sui)
├── templates/                               ← deployable starter templates (serve-vercel — Deploy-with-Vercel target; NOT workspace packages)
├── contracts/                               ← Move sources (a2a_escrow, agent_id — live on mainnet)
├── brandkit/                                ← voice, logos, OG, emails, connector-directory paste packs
├── ops/                                     ← local-only / gitignored (GTM desk · dogfood · settle ledgers · QA · Dune scratch — same class as spec/)
├── scripts/                                 ← release tooling (release-notes.sh)
├── t2000-skills/                            ← agent skills (canonical SKILL.md source; synced to t2000-afi/t2000-skills)
├── .claude/                                 ← agent context (canonical)
│   ├── rules/                               (small always-on subsystem notes)
│   ├── skills/                              (rule depth — loaded on task match)
│   └── commands/                            (/release, /ship, /tracker, /next)
├── .cursor/rules/                           ← pointers into .claude/ for Cursor (not content)
└── tsconfig.base.json, turbo.json,          ← workspace config
    package.json, pnpm-workspace.yaml,
    skills-lock.json                         (provenance + content hashes for vendored skills)
```

> Internal product specs, design decisions, and runbooks live in a local-only `spec/` tree that is not part of the public repo. Ask the maintainers if you need access.
## Where does X go?

| If X is a... | Put it in... |
|---|---|
| Public developer docs page (setup, API ref, examples) | `apps/docs/<slug>.mdx` (Mintlify; deploys to `docs.t2000.ai`) |
| Package README | `packages/<pkg>/README.md` |
| App README | `apps/<app>/README.md` |
| Brand voice / logos / connector paste / marketing one-pager | `brandkit/` |
| Dogfood prompts, manual QA, GTM/settle ledgers, Dune SQL, ops runbooks | local `ops/` (**gitignored** — never the public repo; mirror to private `t2000-internal` if multi-machine) |
| A rule every task needs | `CLAUDE.md` (it loads every turn — keep it tight) |
| A rule only some tasks need | `.claude/skills/<name>/SKILL.md` (write a trigger-rich `description`) |
| A repeatable ritual | `.claude/commands/<name>.md` |
| A Cursor-visible copy of a rule | `.cursor/rules/<name>.mdc` — **a pointer only**, never a second copy of the body |

All public developer docs live in `apps/docs/` (Mintlify). There is no public `docs/` folder — do not recreate one.

If a file would go at the repo root and it's not on the allowlist below, push it into one of the above subdirectories instead.

## Root-level allowlist

These are the ONLY files that should live at repo root (everything else moves to a subdir):

| File | Purpose |
|---|---|
| `README.md` | Public landing page |
| `LICENSE` | MIT |
| `CLAUDE.md` | Agent context (loaded every session by Claude Code) |
| `PRODUCT.md` | The product map — 2 products, their customers, the one path into each |
| `ARCHITECTURE.md` | System architecture reference |
| `REPO_LAYOUT.md` | Contributor "where does X go?" SSOT (this file) |
| `SECURITY.md` | Security disclosure policy |
| `.gitignore`, `.npmrc`, `.prettierrc`, `.nvmrc` | Tooling config (`.nvmrc` pins node 22 — matches CI; node 25+ breaks native deps like sqlite3 + mintlify) |
| `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml` | Workspace |
| `tsconfig.base.json`, `turbo.json`, `glama.json` | Build config |

Plus founder-local truth source (gitignored, not visible publicly):
- `audric-build-tracker.md` (build progress log, ~3 MB rotation policy)
- `PRODUCT_ROADMAP.md` (whole-product master roadmap)
- `HANDOFF_NEXT_AGENT.md` (agent context handoff, ~7d rotation policy)
- `.smoke-*` (live smoke tooling)
- `.env.local` (if present — app env lives in the audric monorepo; this repo’s packages rarely need root env)

## audric repo (sister repo, separate clone)

See `audric/CLAUDE.md` for analogous layout. Key conventions:

- `audric/apps/web-v3/DEPLOY.md` — deploy, cutover, and rollback runbook for the live app
- `audric/.cursor/rules/` — workspace rules (loaded every session)
- `audric/.claude/rules/` — Claude Code rules
- `audric/scripts/` — operational scripts (smoke, env-parity, dump-session)

## Linked references

- `CLAUDE.md` "Key Documents" section — pointer table from agent context
- `audric/CLAUDE.md` — sister repo analogue
