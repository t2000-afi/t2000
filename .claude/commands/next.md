---
description: Read the forward backlog and propose the next task to work on
---

Figure out what to work on next.

## Read these, in this order

1. **`audric/HANDOFF_NEXT_AGENT.md` → "Active backlog" table** — this is the
   canonical, ranked list for product / agent-ownable tasks (with effort + notes)
   plus founder ops. (local-only)
2. **`HANDOFF_NEXT_AGENT.md`** (this repo) — the infra forward window and
   cross-repo cleanup. It defers the product backlog to the audric one, so don't
   treat a gap here as "nothing to do." (local-only)
3. **`PRODUCT.md`** (this repo, **public**) — live product map. Sanity-check
   the candidate is a live door/SKU, not a retired surface or a Designed
   paper. Plan numbers: `audric/packages/accounts/src/tiers.ts`.
4. **Top of `audric-build-tracker.md`** — the last few `S.N` entries, to see what
   just landed and whether it left "founder ops owed" or "held for founder nod"
   items that are now unblocked. (local-only)

Handoffs and the tracker are gitignored, mounted from the private
`t2000-afi/t2000-internal` repo at `spec/`. `PRODUCT.md` is not.

## Then

Propose **one** next task. For it, state:

- What it is and which backlog row it came from.
- Why it's next (rank, or a dependency that just cleared).
- Rough effort.
- The **verifiable acceptance criteria** — what runnable check proves it's done.
- Which surfaces it touches (SDK / CLI / MCP / skills / docs — see `/ship`).

Then run the product algorithm on it before writing any code: is the requirement
actually sound, and is there a version of this task that *deletes* something
instead of adding it? Say so if there is.

**Do not start implementing until the user picks.** List the runner-up briefly so
they can redirect in one word.
