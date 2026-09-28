---
description: Append a new S.N entry to audric-build-tracker.md for the work just shipped
argument-hint: [short title of the slice]
---

Log the slice just shipped to `audric-build-tracker.md`: **$ARGUMENTS**

## What this file is

A reverse-chronological **execution log** — one `S.N` entry per shipped slice,
newest at the top. It is the audit trail, **NOT** a forward backlog (that's
`HANDOFF_NEXT_AGENT.md`). It's gitignored here — the real file lives in the private
`t2000-afi/t2000-internal` repo, mounted at `spec/`.

## Steps

1. Read the top of `audric-build-tracker.md` to get the latest `S.N`. **Increment
   it** — never reuse or guess a number.
2. Confirm the work is actually shipped (committed / deployed), not just written.
3. Insert the new entry immediately below the `**Rules:**` block, above the
   current top entry.

## Entry shape

Match the house style exactly — a heading, a one-line "why" with founder context
where it exists, then bolded-lead bullets:

```markdown
## S.<N> — <title> (<YYYY-MM-DD>)

<One or two lines: the driver / founder rationale / what forced this.>

- **<Category>:** what changed, concretely, with file or package names.
- **<Category>:** …
- **Founder ops owed (not in git):** anything requiring a human — DNS, Vercel
  project deletion, npm deprecate, dashboard changes. Omit if none.
```

Categories used in practice: `Deleted` · `Kept` · `Added` · `Git` · `Docs/config` ·
`Redirects` · `SSOT` · `Archive` · `Rules` · `Held for founder nod` ·
`Founder ops owed`.

## Rules

- **Be specific.** "Updated docs" is useless six months later; name the files.
- **Record what was NOT done** and why — held decisions, deferred pieces, ops owed.
- **Don't editorialize the outcome.** If something is partial or unverified, say so.
- One entry per slice. Don't retro-edit older entries to look tidier.
