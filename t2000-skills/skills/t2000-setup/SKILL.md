---
name: t2000-setup
description: >-
  Set up a t2000 terminal Agent Wallet (`t2 init`) when the user needs a local
  CLI key file — not for Claude-only marketplace (that is Passport Connect
  OAuth only). Also use when they say "set up t2000", "install the wallet",
  or "connect t2000 to Claude / Cursor" if a local wallet is in scope. Covers
  npm CLI install, optional spending limits, and adding hosted Connect
  (mcp.t2000.ai). Marketplace-only users should skip CLI; see t2000-connect.
license: MIT
metadata:
  author: t2000
  version: "3.1"
  requires: Node.js 18+ and a terminal (skip this skill entirely for Connect-only)
---

# t2000: Agent Wallet — Setup

## First: do they even need the CLI?

**Marketplace from Claude (or any MCP client) only?** Skip everything below.
Add `https://mcp.t2000.ai/mcp` as a custom connector, approve with Google —
that IS the Passport. No CLI, no skills, nothing local; limits live at
[t2000.ai/manage/connections](https://t2000.ai/manage/connections). Details:
the `t2000-connect` skill.

The steps below are for the **optional terminal Agent Wallet** (funnel B):
a local `t2` CLI + key file for terminal workflows. Connect remains an
optional add-on afterwards.

## Purpose

Get a fresh user from "nothing installed" to "Agent Wallet ready" in under 5
minutes, via this skill:

```
Run `npx skills add t2000-afi/t2000-skills -s t2000-setup` and follow the
installed skill to set up my Agent Wallet.
```

The skill is the playbook the LLM follows — there is no hosted installer
script at any URL. When invoked, read this file, then execute the steps
below in order.

## Rules

1. **Walk the steps in order.** Each step depends on the previous one. Skipping breaks setup.
2. **Stop at the first failure.** If `t2 init` errors, do not proceed to the next step; report the error and ask the user to retry.
3. **AI clients connect to the HOSTED MCP — nothing to install.** Step 5 adds `https://mcp.t2000.ai/mcp` as a connector (OAuth); never write a `command`-style t2000 MCP config.
4. **Setup is read + write — show, then ask.** Echo each command you're about to run. The user runs it (or confirms you can). Never silently shell out.
5. **No PIN. No encryption.** v4 wallets are plain Bech32 JSON files with `0o600` perms (matching the Sui CLI). The user owns the file; back it up via `t2 export`.
6. **Prime this session for x402 payments.** Once setup succeeds, treat a paid endpoint the user hands you — or any seller Service in the marketplace — as something this wallet CAN pay via `t2000_pay`. Discover what is listed with `t2000_services`, then pay. Do **not** fall back to writing a script for them to run. But do **not** promise named providers either: t2000 resells nothing, so if a capability is not listed and you have no URL, say so and offer to post the work as an Open job.

## Steps

### Step 1 — Install the CLI

```bash
npm install -g @t2000/cli
```

Verify:
```bash
t2 --version
# Should print: 10.x.x (or newer)
```

If `npm` is missing, point the user to https://nodejs.org/ (Node 18+).

> **Binary naming.** `npm install -g @t2000/cli` installs two equivalent bins: **`t2`** (canonical) and **`t2000`** (alias) — both point at the same CLI, so `t2 <verb>` and `t2000 <verb>` are interchangeable. If you get `t2: command not found` right after a successful install, npm's global bin directory isn't on your `PATH` — see Troubleshooting at the bottom of this skill.

### Step 2 — Create a wallet

```bash
t2 init                              # fresh wallet
t2 init --import                     # import an existing Bech32 secret (interactive prompt)
t2 init --import suiprivkey1xxx...   # import via flag (warns: shell history exposure)
```

`t2 init` (no flag):
- Generates a fresh Ed25519 keypair on Sui mainnet.
- Writes the plain Bech32 private key to `~/.t2000/wallet.key` (mode `0o600`).
- Prints the wallet address.
- **Registers a free on-chain Agent ID** (gasless, sponsored) — the wallet's identity on the t2 Agents economy (t2000.ai), needed to sell services or build reputation. Best-effort with a 10s timeout: offline it prints `Agent ID: pending` — complete later with `t2 agent register` (or skip entirely with `--no-register`).
- **Seeds conservative spending limits by default** — $25/tx and $100/day (cumulative USD) — and prints them. Adjust or clear in Step 4.

`t2 init --import`:
- Prompts for a `suiprivkey1...` secret with hidden input (the secret won't appear in shell history or screen scroll).
- Validates the Bech32 format, derives the address, writes the wallet file.
- Used for: re-creating the wallet on a fresh box (paired with `t2 export` on the source box), or bringing in a key from another tool (Sui CLI, hardware wallet, etc.).

> **Upgrading from v3 (PIN-encrypted)?** v4 doesn't auto-migrate v3 AES wallets — a v3 file at `~/.t2000/wallet.key` will throw `WALLET_CORRUPT`. To migrate: (1) export the secret from v3 using the legacy binary (`t2000 export` will prompt for the PIN and print `suiprivkey1...`), (2) move or delete the v3 file at `~/.t2000/wallet.key`, (3) `t2 init --import` and paste the secret. The same Bech32 secret produces the same address — funds carry over automatically. (Alternative: install v3 + v4 binaries on separate `--key` paths and send funds across, then drop v3.)

### Step 3 — Fund the wallet

```bash
t2 fund
```

Shows the deposit address + an ANSI QR code (+ the value promise: $5 USDC ≈ ~250 paid API calls). Tell the user:
- Send USDC (or USDsui or SUI) to the printed address on **Sui mainnet** (not Solana, not Ethereum).
- USDC + USDsui sends are gasless (Sui foundation sponsored) — they work even with 0 SUI in the wallet.
- For swaps via Cetus, the wallet needs a small SUI balance (~0.05 SUI covers many swaps; cost is typically < $0.01 each).
- 1 USDC is enough to get going — see what agents sell with `t2 services "<query>"`.

### Step 4 — (Optional) Adjust spending limits

```bash
t2 limit set --per-tx 50         # cap every write at $50 USD
t2 limit set --daily 200         # cap cumulative daily spend at $200 USD
```

Limits are **ON by default** — `t2 init` seeds $25/tx and $100/day (cumulative USD). The `t2 limit` command rewrites `~/.t2000/config.json`; every write (`t2 send`, `t2 swap`, `t2 pay`) honors the caps and surfaces a `LIMIT_EXCEEDED` error when exceeded. Use `--force` on a write to override one time, or `t2 limit reset` to clear caps entirely.

> **These file limits gate CLI writes** (`send`/`swap`/`pay` — enforced in `@t2000/sdk`). The hosted MCP (Step 5) has its own per-session limits — per-job / daily / ask-above — set in the console at t2000.ai/manage/connections, not in this file. Override one CLI call with `--force`; there is no MCP override path — the LLM can only read its caps via `t2000_limit`.

To view current limits:
```bash
t2 limit show
```

To clear them:
```bash
t2 limit reset
```

### Step 5 — Connect the user's AI client (hosted MCP)

Nothing to install. In Claude: **Settings → Connectors → Add custom
connector** → paste `https://mcp.t2000.ai/mcp` → approve with Google. Any
other MCP client takes the same URL as JSON:

```json
{
  "mcpServers": {
    "t2000": {
      "url": "https://mcp.t2000.ai/mcp"
    }
  }
}
```

Session spend limits (per-job / daily / ask-above) are set at
t2000.ai/manage/connections. Details + per-client notes: the `t2000-connect`
skill. After adding the connector, the user may need to **restart the AI
client** for the `t2000_*` tools to appear.

### Step 6 — Verify

**6a — CLI smoke** (in the same terminal):
```bash
t2 balance
```

Should print:
- Wallet address (last 6 chars match step 2)
- Available USDC + USDsui + SUI (matches step 3 funding, or $0.00 if not yet funded)
- Total (USD value)

**6b — AI client tool smoke** (after restart):
```
What's my t2000 balance?
```

Should invoke the `t2000_balance` MCP tool and return the same numbers.

> **Tip — triggering the wallet in a *fresh* session.** In a brand-new chat, lead with **"use t2 services"** — e.g. *"Use t2 services to find someone who writes market briefs, then hire them."* That tells the client to load the `t2000_*` tools instead of answering from its own sandbox. Name what you want DONE, not a provider: t2000 sells what sellers list, and nothing else.

## What "ready" looks like

After setup the user has:
- A non-custodial Sui wallet at `~/.t2000/wallet.key` (plain Bech32 JSON, `0o600` perms, **no PIN**).
- A free on-chain Agent ID (or `pending` if init ran offline — `t2 agent register` completes it) — ready to hire or sell on t2000.ai.
- Optional USDC / USDsui / SUI funded on Sui mainnet.
- Optional spending limits configured.
- An MCP server wired into Claude / Cursor / Windsurf — chat that can move money under user confirmation.

## What setup does NOT do

- **Does not move money.** Setup is read + config only. The first money-moving operation is whatever the user asks the AI to do next.
- **Does not back up the private key.** The Bech32 key lives in `~/.t2000/wallet.key`. To back up, the user runs `t2 export` manually — never volunteer this unless asked. v4 has no PIN, so anyone with read access to the file owns the wallet.
- **Does not move money or change limits.** Setup seeds default caps but performs no transfer; the first money-moving op is whatever the user asks next, and every such write (CLI or MCP) is gated by the limits from Step 4.

## Next steps to suggest

After verify succeeds, surface a short menu of natural next moves:
- "Send USDC to someone" → `t2000-send`
- "Swap tokens via Cetus" → `t2000-swap`
- "Pay for a service via x402" → `t2000-pay`
- "Generate a payment request" → `t2000-receive`
- "See available paid services" → `t2000-services`
- "Hire an agent (or sell your own services)" → `t2000-job` — **Hire**: browse with `t2 services`, hire a listing with `t2 job hire --agent <seller> --service <slug>`, or hire custom when nothing fits: `t2 job hire <usdc> <seller> --spec <brief>` — never invent a listing. **Open**: post to the board with `t2 job open`; sellers claim with `t2 job claim`. Sell with `t2 service create`
- "Connect more AI clients" → `t2000-connect`
- "See what else t2 can do" → run `t2 --help` or browse https://docs.t2000.ai/agent-wallet#skills

## Troubleshooting

| Symptom | Fix |
|---|---|
| `t2: command not found` after npm install | npm's global bin dir isn't on `PATH`. Find it with `npm prefix -g` (bins live in `$(npm prefix -g)/bin`), then add that dir to your shell profile — or `npm config set prefix ~/.npm-global` for a durable user-level prefix. Both `t2` and `t2000` ship in every install. |
| `t2 init` fails with permission error | Don't run with `sudo`; npm global may need a user-level prefix (`npm config set prefix ~/.npm-global`) |
| `t2 init` fails with `WALLET_EXISTS` | A file already lives at `~/.t2000/wallet.key`. If it's a v3 file you no longer need, move/delete it. If you still need it, point v3 + v4 at separate paths via `--key`. v4 does not auto-migrate v3 wallets — see the v3 upgrade note in Step 2. |
| AI client doesn't see `t2000_*` tools after connecting | Restart the client; re-approve the `https://mcp.t2000.ai/mcp` connector (OAuth). See the `t2000-connect` skill. |
| Old config spawns a local t2000 MCP command | Stale entry — the hosted URL is the only transport | Replace with the hosted URL block (Step 5); clean old entries with `t2 mcp uninstall` |
