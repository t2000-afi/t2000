# Proposal: close the x402 replay and payer-trust gaps in the seller path

**Status: proposed, not implemented.** This is a change plan for review, written during the t2000 v2 Phase 0 review of the live pay-per-call path. It contains no code. Each section names its tests first, then the changes by file. A person implements and merges it; nothing here edits the v1 tree.

## Why

The seller template (`templates/serve-vercel`) deployed with its default configuration is exposed to payment replay, and runs a handler under a payer address it has not verified. Both were found by reading `@t2000/serve` and `@t2000/sui-x402` and confirmed on mainnet:

- A node answers a re-submission of already-executed transaction bytes with the original success (tested: one gasless USDC self-transfer submitted three times, executed once, each submission returned success). So the signed `X-PAYMENT` bytes can be presented again.
- Replay safety rests entirely on the seller's digest store. `createServeFromEnv` uses an in-memory store unless `KV_REST_API_URL` and `KV_REST_API_TOKEN` are both set, and only warns when they are not. On a serverless host each instance has its own memory, so a replay landing on another instance is served again, as the original payer.
- The challenge id is taken from the payment itself (`expected.challengeId = payment.payload.challengeId`), so "challenge-once" is a deny-list of consumed ids, not an allow-list of issued ones.
- The handler runs before the signature is verified, under the payer address the request claims, so a forged payload runs the handler as a victim and, for a payer-gated route, can read or mutate the victim's resource.
- The payment is bound to a challenge id, not to a route, so a payment for route A is accepted by route B at the same price.

Full evidence, with file and line references and the mainnet digest, is in the v2 review pack (`PPC-PROOF.md`). The template pins `@t2000/serve ^10.1.0`, which resolves to 10.41.0, so a fix must reach the release line the template installs, not only the latest.

## Finding 2.1 — accept only challenges the server issued

**Tests first** (`packages/serve/src/route.test.ts`):
- A payload carrying a made-up challenge id whose nonce matches gets 402, and the handler never runs.
- A challenge id presented twice gets 402 on the second presentation.
- A challenge whose issue record has expired gets 402.

**Changes:**
- `packages/x402/src/store.ts`: add a `ChallengeStore` interface beside `DigestStore` — `issue(id, route, priceRaw, ttlSeconds)` and `consume(id)`, where `consume` atomically returns the stored route and price and deletes the record, or returns nothing. Implement it on `InMemoryDigestStore`.
- `packages/serve/src/store.ts`: implement `ChallengeStore` on `UpstashDigestStore` — `issue` as `SET … EX … NX`, `consume` as `GETDEL` (atomic).
- `packages/serve/src/route.ts`, `respond402`: after building requirements, `issue(challengeId, path, maxAmountRequired, ttl)` with a TTL covering the challenge's epoch window.
- `packages/serve/src/route.ts`, paid branch: before structural verification, `consume(payment.payload.challengeId)`; 402 if it returns nothing; pass the consumed id into `verifyX402Payment` as `expected.challengeId`, not the payload's. Remove the separate `challenge:<id>` has/set, which `consume` replaces.
- `packages/x402/src/x402.ts`, `verifyX402Payment`: no logic change; document that `expected.challengeId` must come from server state.

## Finding 2.4 — a durable store, checked before any work

**Tests first:**
- `packages/serve/src/serve-env.test.ts`: `createServeFromEnv` with no KV configured on a detected serverless host throws at construction.
- `packages/serve/src/route.test.ts`: two requests with the same `X-PAYMENT` against two `Serve` instances sharing one store — the second gets 402 and its handler never runs. Two concurrent duplicates — exactly one handler call. A payment whose `maxEpoch` is below the current epoch gets 402.

**Changes:**
- `packages/serve/src/serve.ts`, `createServeFromEnv`: refuse to start without a durable store. Allow an explicit `T2000_REPLAY_STORE=memory` escape for a single long-lived process, refused when a serverless host is detected (e.g. a `VERCEL` env var or a Workers binding present).
- `packages/x402/src/x402.ts`: add a helper that computes the transaction digest from the signed bytes locally (no RPC); add an expiry check that refuses when `ValidDuring.maxEpoch` is below the current epoch.
- `packages/serve/src/route.ts`, paid branch: after structural verification and before the handler, claim the digest with `SET NX`; refuse if the claim fails; pass the current epoch (from `getChainInfo`) to the expiry check. The post-execution `store.has(digest)` inside `settleX402Payment` becomes a consistency check, not the guard.
- `packages/serve/src/store.ts`: base the TTL on the payment's `maxEpoch` plus a margin rather than a fixed 72 h. (The margin depends on the pending epoch-window re-submission check in the review pack; set it once that result is in.)
- `templates/serve-vercel/README.md` and the Deploy-with-Vercel button: make the durable store a required deploy step and include the storage integration in the button. Bump `templates/serve-vercel/package.json` from `@t2000/serve ^10.1.0` to the patched release line.

## Finding 2.7 — verify the signature before the handler

**Tests first** (`packages/serve/src/route.test.ts`):
- A payload with a valid structure and an invalid signature gets 402, and the handler is never called.
- A zkLogin-signed payload passes, using a mocked client.

**Changes:**
- `packages/x402/src/x402.ts`: add an async `verifyX402Signature` built on `verifyTransactionSignature` from `@mysten/sui/verify`; it takes a client (so zkLogin verifies) and checks that the recovered address equals `senderAddress`.
- `packages/serve/src/route.ts`, paid branch: call it after structural verification and before the handler; a failure answers 402 and the handler never runs.
- `packages/serve/src/route.ts`, `RouteBuilder`: add a per-route option to settle before running the handler, for routes with side effects or payer-gated resources; on such a route a handler failure is charged and the 500 body says so; mark the option in `/openapi.json` so buyers see it.
- `packages/serve/README.md`: document both orders and when each applies.

## Finding 2.8 — bind the payment to the route

**Tests first** (`packages/serve/src/route.test.ts`):
- A challenge issued for route A, presented with a payment to route B of the same instance, gets 402.

**Changes:**
- `packages/serve/src/route.ts`, paid branch: compare the route and price returned by `consume` (finding 2.1) with the route being called and its price; 402 on a mismatch. No wire-format change.

## Release and rollout

- `.github/workflows/release.yml`: one lockstep release as usual; the fix must land in the version range the template installs.
- A release does not update existing seller deployments. Each seller redeploys, and adds a durable store if they have none. The redeploy notice to sellers is a separate, outward message for the founder to send; a draft lives in the v2 review pack.
