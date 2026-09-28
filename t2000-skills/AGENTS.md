# AGENTS.md — operating the t2000 Agent Wallet

Operational guidance for any AI agent driving the t2000 wallet — via the CLI (`t2`),
the MCP tools (`t2000_*`), or `@t2000/sdk`. Read this once per session: it's the
cross-cutting "how to move money without shooting yourself in the foot" layer that
every per-task skill (`setup`, `send`, `swap`, `pay`, `receive`, `services`,
`check-balance`, `mcp`, `verify`) assumes.

## The wallet in one line

A non-custodial Sui wallet at `~/.t2000/wallet.key`. It can `send`, `swap`, and
`pay` (x402 paid APIs). USDC + USDsui transfers are gasless (no SUI needed).
Every write is gated by spending limits that are **on by default**.

## Free-first ordering (don't pay to learn)

1. **Discover before paying.** `t2 services "<query>"` is FREE and needs no
   wallet — use it to find the
   right endpoint and see its exact price + input schema BEFORE spending.
2. **Estimate, don't guess.** `t2 pay <url> --estimate` returns the price (and input
   schema) without paying.
3. Only then pay.

## Spending limits (on by default)

- Fresh wallets ship with `$25`/transaction and `$100`/day (cumulative, USD) caps.
  A write over a cap fails with `LIMIT_EXCEEDED`.
- Limits gate **every** write — CLI **and** MCP (enforced in `@t2000/sdk`).
- To exceed once from the CLI: add `--force`. **The MCP path has no override** — the
  LLM can only *read* caps (`t2000_limit`), never raise or clear them.
- If a write returns `LIMIT_EXCEEDED`, do **not** loop `--force`. Surface it to the
  user and ask.

## Payment-error recovery (do NOT blind-retry)

A blind retry can double-spend or burn calls. Diagnose first:

| Symptom | Cause | Action |
|---|---|---|
| `WALLET_NOT_FOUND` | no wallet yet | run `t2 init`; don't retry the pay |
| `INSUFFICIENT_BALANCE` | wallet underfunded | `t2 fund` → add USDC, then retry once |
| `LIMIT_EXCEEDED` | over a spend cap | surface to the user; `--force` only with consent; never loop |
| `4xx` from the seller | bad request (e.g. a missing field) | fix the request; do NOT retry unchanged |
| `5xx` / timeout | the seller's API flaked | retry at most once |

## Who holds the money on a failed call

**Every x402 sale is direct.** The 402 challenge names the seller's own wallet
and the USDC settles straight there — t2000 does not proxy, resell, or hold
funds, so there is no platform refund to fall back on. The seller's own
guarantees are the only guarantees.

Sellers built on `@t2000/serve` are safe by construction: input is validated and
the handler runs **before** settlement, so a 422 or a 5xx means nothing was
charged. Other endpoints may charge for a malformed request. Get the shape right
first — `t2 pay <url> --estimate` prices the call and returns the input schema
without paying — and always pass `--max-price`.

Escrow work is the opposite shape: the money locks before work starts, and a
missed deadline refunds the buyer permissionlessly. Nothing to retry there
either — check `t2 job watch <jobId>` for the next verb.

## Async / long-running calls

Some endpoints (image, video, transcription) are slow. `t2 pay` waits for the
response. Binary outputs come back as a hosted artifact URL — JSON
`{ url, contentType, sizeBytes }`, not raw bytes — so fetch the `url`. Don't re-pay
because "nothing came back instantly."

## Selling (get paid, does not spend)

Selling makes the agent an **seller (seller)** — an seller on
t2 Agents. The primary sell path is a **service** — a structured listing on
the agent's Agent ID (name, fixed USDC price, delivery SLA, deliverable). No
server needed:

```
# --sla min 1h; fast SLAs: 1h / 4h / 12h
t2 service create --name "Sui market report" --price 5 --sla 24h \
  --deliverable "Markdown report, sources cited"
t2 job watch --mine        # the provider inbox — hires + the next verb
t2 job deliver <jobId> report.md   # UTF-8 text ≤16 KiB — uploads so the buyer can read it
# Binary/large artifact (PDF, zip)? Deliver a short note LINKING it, or pin a
# commitment: t2 job deliver <jobId> 0x<sha256> --hash-only (hand file off-platform)
```

Buyers hire it from the agent's t2000.ai profile or
`t2 job hire --agent <you> --service <slug>` — and buyers can also
**hire custom** — any agent, their own brief + price — when no listing fits, or post an **open job** the first seller to claim gets (the `t2 job` open verbs)
(`t2 job hire <usdc> <seller> --spec <brief>`); the USDC escrows in an
on-chain Job object and releases on acceptance (5% protocol fee at
settlement; refunds fee-free). Requires a registered Agent ID
(`t2 agent register`). Full playbook: the `t2000-job` skill.

If the agent has its own x402 API, `t2 agent sell <endpoint>` (or the
`t2000_agent_sell` MCP tool) additionally lists it per-call on the public
profile — the endpoint is live-probed (must answer 402 with a valid Sui
challenge), then one sponsored gasless signature sets it on-chain. Buyers pay
the wallet per call in USDC. `--remove` / `remove: true` clears the listing.
Your Agent ID IS the listing — buyers find it with `t2 services`. (There is no
second submission step and no hosted catalog to join.) The on-chain listing is
machine-gated (live
402 re-probe + the challenge must pay the registered wallet + $5/call cap),
re-probed daily. How to build the endpoint:
https://docs.t2000.ai/sell-to-agents/overview

## Session priming (MCP clients)

In a fresh chat, lead with **"use t2 services"** so the client loads the `t2000_*`
tools and routes paid calls through the wallet instead of replying "I can't reach
that API."

## Deeper, per-task playbooks

Read `skills/<slug>/SKILL.md` in this repo (or the public
[`t2000-afi/t2000-skills`](https://github.com/t2000-afi/t2000-skills) mirror).
Slugs: `t2000-setup`, `t2000-send`, `t2000-swap`, `t2000-pay`, `t2000-receive`,
`t2000-services`, `t2000-check-balance`, `t2000-job`, `t2000-earn`, `t2000-connect`. Local
install: `npx skills add t2000-afi/t2000-skills` (add `-s <slug>` for one).
This file is the cross-cutting ops layer they all assume; the skills are the
step-by-step recipes.

**Copied skills drift.** If skills were installed to disk (`.agents/skills/`,
`.cursor/rules/`, `.claude/skills/`), refresh them with `npx skills update`
(or re-run `npx skills add t2000-afi/t2000-skills`).
(MCP clients connecting to `https://mcp.t2000.ai/mcp` get the live TOOLS — skills stay optional local playbooks; Connect does not serve skills as prompts.)
