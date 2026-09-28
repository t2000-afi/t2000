# @t2000/docs — `docs.t2000.ai`

Source for the Mintlify-hosted developer documentation site at [`docs.t2000.ai`](https://docs.t2000.ai).

Nav groups (`docs.json` is the SSOT): **Getting Started** · **How to** ·
**Reference**. Release history lives on
[GitHub Releases](https://github.com/t2000-afi/t2000/releases) (the navbar
Changelog link) — there is no Mintlify changelog page (S.1072).

Models are not documented here. Private Inference is an
[Audric](https://audric.ai) product (SPEC_PI_TO_AUDRIC, 2026-08-01) —
Gateway ZDR only (the confidential/TEE tier was removed 2026-08-18, S.1095).

**Redirects: one deliberate exception.** `docs.json` carries a single
`redirects` entry — `/prompts` → `/tools` (the prompt directory became the
Connect tools catalog; external links to `/prompts` were already in the
wild). Nothing else redirects: any other retired URL 404s rather than
forwards, so every link inside the docs must point at a page that actually
exists. Do not add more redirects — rename pages by fixing the links.

## Local development

```bash
pnpm install
pnpm --filter @t2000/docs dev
```

Opens `http://localhost:3000` with live reload.

<!-- prettier-ignore -->
> **Node version.** The Mintlify CLI 4.x requires Node LTS (22 or 24). The rest of the monorepo runs on Node 25, so `mintlify dev` / `mintlify validate` will fail with `not supported on node versions 25+` if you don't switch first.
>
> ```bash
> nvm use 22       # or fnm use 22 / brew switch
> pnpm --filter @t2000/docs dev
> ```
>
> Structural validation that runs on any Node version:
>
> ```bash
> jq . apps/docs/docs.json     # JSON valid
> # every nav page exists, and no redirect shadows a live page:
> jq -r '.navigation.tabs[].groups[]?.pages[]?, .navigation.tabs[].pages[]?' apps/docs/docs.json |
>   while read p; do test -f "apps/docs/$p.mdx" || echo "✗ MISSING $p.mdx"; done
> # no internal link points at a page that doesn't exist:
> grep -rhoE '\]\(/[a-z0-9/-]+' apps/docs --include='*.mdx' | cut -c3- | sort -u |
>   while read l; do test -f "apps/docs${l}.mdx" || echo "✗ DEAD LINK $l"; done
> ```

## Source of truth

Each page is a curated, Mintlify-flavored view of the canonical package README:

| Page | Pulls from |
|---|---|
| `index.mdx` | repo `README.md` top-level value prop |
| `agent-wallet.mdx` | `packages/cli/README.md` + `t2000-skills/README.md` |
| `how-to/pay-an-api.mdx` | `packages/cli/README.md` (pay section) |
| `how-to/sell-your-api.mdx` | `packages/serve/README.md` |
| `agent-sdk.mdx` | `packages/sdk/README.md` |

The `how-to/*` pages are scenario steps (Connect paste + `t2` commands) — flags
must match the live CLI (`t2 <cmd> --help`), prices per the docs SPEC.

When a README changes, mirror the relevant section into the corresponding `.mdx`. Don't fork — keep the README the source-of-truth.

## Deployment

Mintlify auto-deploys on every push to `main` once the project is connected via [Mintlify dashboard](https://dashboard.mintlify.com/). CNAME `docs.t2000.ai` → `cname.mintlify.app`.

## Brand

- Primary color: `#00D395` (matches the README docs badge across packages).
- Voice: Circle-style — short value prop, table-driven sections, code blocks as the verb.
- "Agent" not "Agentic" in consumer-facing copy (per `SPEC_AGENT_WALLET_GREENFIELD.md` locked decision 8).
