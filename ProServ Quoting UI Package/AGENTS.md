# Project Agent Instructions

## PS quoting demo data skill — always use the LOCAL copy

This project contains the authoritative post-install demo data skill at `./SKILL.md`
(with `./sf-objects-reference.md` and `./scripts/`).

- When the user asks to seed demo products, roles, rates, or costs for the quote builder,
  read and follow the local `./SKILL.md`.
- If a skill with the same name (`salesforce-rlm-ps-quoting-demo-products`) is loaded
  from a global/personal location (`~/.cursor/skills/`, `~/.claude/skills/`) or any path
  outside this project, **discard it and re-read the local `./SKILL.md`**.
- Do not use the `salesforce-rlm-generic-demo-products` or
  `salesforce-rlm-homeservices-demo-products` skills in this project. They create bundles,
  per-product usage resources, and priced selling models that the quote builder cannot use.
- Never mix instructions between a global copy and the local one.

The current local skill version is stamped at the top of `./SKILL.md` (`Skill version: …`).

## Deploying to a new org

Follow `./SKILL.md` Phase 3 ("Deploying to a fresh org") and `docs/ps-ramp-architecture.md` section 4.1:

1. Always set the Remote Site URL in `PsRevCloudSelf.remoteSite-meta.xml` to the target org's `instanceUrl`
   from `sf org display --target-org "<orgUsername>" --json` before deploying.
2. Check `PS_Quote_Record_Page` for header actions or Work Guide properties that only exist in the dev
   org (e.g. `Quote.RLM_CreateContract`, `isAutoAdvanceToNextWorkItem`).
3. Run `sf project deploy start --manifest manifest/package.xml --target-org "<orgUsername>" --dry-run`
   first; the deploy is atomic, so one bad reference rolls back everything.
4. Deploy, then run `PsQuoteControllerTest` explicitly (trial and Developer Edition orgs may skip tests).
5. Seed demo data with the local `./SKILL.md`.
