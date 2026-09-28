# Package Rules

The stack is **6 packages**, always released together at the same version:
`@t2000/{sdk,cli,id,serve,sui-x402,discovery}` (dialect dir = `packages/x402`; npm name `sui-x402` — `@t2000/x402` is an unpublish tombstone; the stdio `@t2000/mcp` was deleted 2026-08-03, deprecated on npm, Connect is the MCP surface).

## @t2000/sdk (packages/sdk)

- Entry: `src/index.ts`
- Exports: Agent class, account types, transaction builders
- Write surface: **send** (gasless USDC/USDsui) · **swap** (Cetus) · **pay** (x402).
  No DeFi builders — NAVI/lending left the SDK 2026-06-14.
- All public functions need explicit return types
- Scope: `sdk`

## @t2000/cli (packages/cli)

- Entry: `src/index.ts` → Commander.js. Bin: `t2` (primary) + `t2000` (alias).
- Surface (matches `program.ts` registration): `init` · `export` · `fund` ·
  `balance` · `history` · `status` · `send` · `swap` · `pay` · `models` ·
  `connect` · `services` · `limit` · `mcp` · `agent` · `agents` · `reviews` ·
  `job` · `service` (+ `browse`, a deprecated `services` alias). Skills install
  via `npx skills add t2000-afi/t2000-skills` — there is no `t2 skills`
  command. (`receive` is SDK-only: `agent.receive` builds payment-request URIs.)
- Keep output consistent with existing commands; test with `--help` / `--dry-run`.
- Scope: `cli`

## @t2000/id (packages/id)

- Agent ID — `agent_id::registry` client. Joined the release lockstep at `5.7.0`.
- Scope: `id`

## @t2000/serve (packages/serve)

- Merchant-side x402 router — wrap any API for agent payments. Joined at `10.1.0`.
- Scope: `serve`

## @t2000/sui-x402 (packages/x402)

- The x402 payment dialect for Sui (scheme `exact`, sign-then-settle gasless
  USDC): requirements builders, header parse/verify/settle, DigestStore.
  Absorbed from `@suimpp/mpp`'s ./x402 surface 2026-08-03 (B1) — **never**
  add the mppx pay loop (Method/Credential/Receipt/WWW-Authenticate) here.
  Wire format (headers, `extra.suimpp` field names) is protocol SSOT — do
  not rebrand it.
- Scope: `x402`

## @t2000/discovery (packages/discovery)

- x402 endpoint probe (accepts[] + WWW-Authenticate) + OpenAPI paid-endpoint
  extract/validate. Absorbed from `@suimpp/discovery@0.2.2` 2026-08-03.
  Zero runtime deps; serve's integration test is the serve↔probe CI gate.
- Scope: `discovery`

## Publishing

**Use `/release`.** The process is mandatory and documented in
`CLAUDE.md § Release process`: trigger `release.yml` via
`gh workflow run release.yml --field bump=<patch|minor|major>`, which bumps all 6
packages, commits, tags, and dispatches `publish.yml`.

**Never** bump versions by hand, push a `vX.Y.Z` tag by hand, or run
`pnpm publish` / `npm publish` locally.

Local build for development only: `pnpm --filter @t2000/<pkg> build`.

## Retired

`@t2000/engine` was deleted from the monorepo 2026-06-14 (S.442) — see
`CLAUDE.md § Critical Rules` #1 for the do-not-reintroduce guard. Historical API
detail: `git log` + `@t2000/engine@4.x` on npm.
