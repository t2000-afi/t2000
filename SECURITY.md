# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| The current published lockstep (latest major) | ✅ |
| Earlier majors | ❌ |

`@t2000/{sdk,cli,id,serve,sui-x402,discovery}` release together at one
version — only the latest major receives security fixes. The hosted MCP
surface (Passport Connect) lives in the audric repo (`audric/apps/mcp`) and is
patched with that app, not as an npm package.

## Reporting a Vulnerability

**Do NOT open a public GitHub issue for security vulnerabilities.**

**GitHub Security Advisories** (preferred): [Report a vulnerability](https://github.com/t2000-afi/t2000/security/advisories/new)

Include: a description, steps to reproduce, potential impact, and a suggested fix
if you have one.

### Response timeline

- **Acknowledgment**: within 48 hours
- **Initial assessment**: within 5 business days
- **Fix timeline**: critical issues within 7 days, others within 30 days

### Scope

- `@t2000/sdk` — key handling, transaction building, gasless send / swap / pay,
  spend-limit enforcement
- `@t2000/cli` — input validation, wallet file handling (`~/.t2000`, `0600`)
- `@t2000/id` — `agent_id::registry` transaction builders
- `@t2000/sui-x402` + `@t2000/discovery` — the x402 dialect (requirements,
  verify, settle, replay store) and the endpoint probe
- Passport Connect (`audric/apps/mcp`) — report here too; it is the same team
- Move contracts (`contracts/`) — `agent_id::registry` (ownership / kill-switch
  authorization) and `a2a_escrow` (escrow + reputation integrity)
- `@t2000/serve` — merchant-side x402: challenge issuance, settle verification, upstream
  API-key isolation
- Websites (`apps/docs`) — XSS, injection

### Out of scope

- Retired packages still on npm (`@t2000/engine`, the stdio `@t2000/mcp`) — unsupported
- Social engineering; DoS via rate limiting (implemented)
- Vulnerabilities in third-party dependencies (report upstream)

## Security Measures

- **Non-custodial keys** — Ed25519, Bech32 JSON at `0600`; the private key never
  leaves the user's machine. (No PIN/passphrase layer by design — the security
  boundary is the filesystem ACL; see `ARCHITECTURE.md § Substrate — the Agent Wallet`.)
- **Default-on spending limits** — per-tx + daily caps enforced inside the SDK,
  gating CLI **and** MCP writes.
- **Payment verification** — challenge-bound signed payments, structurally
  verified before settlement; the handler runs BEFORE money moves, so a
  failing seller never charges the buyer (no-charge-on-failure).
- **Automated scanning** — CodeQL + dependency audit in GitHub Actions.

## Audit Status

**Last audit**: March 2026 (automated full-stack review)
**Status**: findings remediated on a rolling basis — contact the maintainers for
the report.

Live on mainnet with real USDC and still moving fast — use at your own risk.
