# Sell your API to agents — in 5 minutes

A deployable agent-payable API on Sui, built with
[`@t2000/serve`](https://www.npmjs.com/package/@t2000/serve). One paid demo
route (`POST /haiku`, 0.01 USDC), discovery docs, replay protection — swap the
demo handler for your real API and you're selling.

[![Deploy with Vercel](https://vercel.com/button)](https://vercel.com/new/clone?repository-url=https%3A%2F%2Fgithub.com%2Ft2000-afi%2Ft2000%2Ftree%2Fmain%2Ftemplates%2Fserve-vercel&env=T2000_PAY_TO&envDescription=Your%20Sui%20address%20%E2%80%94%20payments%20settle%20here.%20No%20wallet%3F%20npm%20i%20-g%20%40t2000%2Fcli%20%26%26%20t2%20init&project-name=my-agent-api&repository-name=my-agent-api)

## What you get

- **`POST /haiku`** — a paid route: 402 challenge → buyer signs a gasless USDC
  payment → this app verifies, runs the handler, settles. Invalid input or a
  failed handler never charges anyone.
- **`GET /openapi.json` + `GET /llms.txt`** — discovery docs agents (and the
  x402 tooling) read.
- **No keys, no gas.** The buyer's signed transaction is submitted on the
  sponsored gasless rail. Your server holds nothing worth stealing.

## Deploy

1. Click the button above (or clone this folder).
2. Set `T2000_PAY_TO` — your Sui address. No wallet? `npm i -g @t2000/cli && t2 init && t2 address`.
3. Production on Vercel: add **Upstash for Redis** from the Storage tab
   (injects `KV_REST_API_URL`/`KV_REST_API_TOKEN` — durable replay protection).

Settled calls show on the [t2000.ai](https://t2000.ai) home stream and your seller profile by
default (chain-verified reports, never affecting buyer responses) — opt out
with `T2000_ACTIVITY_REPORT_URL=false`.

## Test your live endpoint

```bash
# The 402 challenge (free):
curl -s -X POST https://<your-app>/haiku -H 'content-type: application/json' -d '{}' | jq

# Pay it for real (needs a funded wallet — `t2 receive` prints your address):
t2 pay https://<your-app>/haiku --data '{"topic":"sui"}'
```

## Get listed

```bash
# Dry-run against the catalog gates:
npx @t2000/cli agent register     # free, gasless Agent ID \
  -d '{"url":"https://<your-app>/haiku"}'
# List for real:
npx @t2000/cli agent sell <your-endpoint-url> \
  -d '{"url":"https://<your-app>/haiku"}'
```

Your API becomes a Service on your Agent ID, with a store page on
[t2000.ai](https://t2000.ai).

## Add your own routes

```ts
// app/your-route/route.ts
import { asNextRoute } from '@t2000/serve';
import { z } from 'zod';
import { serve } from '../../lib/serve';

const input = z.object({ q: z.string() });

export const { POST, OPTIONS } = asNextRoute(
  serve
    .route({ path: 'your-route', description: 'What it does' })
    .paid('0.05')
    .body(input, z.toJSONSchema(input))
    .handler(async ({ body }) => yourExistingLogic(body)),
);
```

Export `OPTIONS` too (`asNextRoute` does it) — Next only dispatches exported
methods, and without it browser buyers fail CORS preflight.

Then add `import '../your-route/route'` to `app/openapi.json/route.ts` and
`app/llms.txt/route.ts` so it appears in the discovery docs.

Full guide: [docs.t2000.ai](https://docs.t2000.ai)
