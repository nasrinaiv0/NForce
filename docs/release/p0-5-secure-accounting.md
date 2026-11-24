# P0.5 secure accounting acceptance candidate

Parent PR #11 at 3f0aca6242ceca432958ee971b36a82d62778365; no production changes. No remote migrations or paid resources.

- Disabled-by-default, time-limited, privileged-administrator controlled fictional tenant review gate. Read-only aggregate RPC returns original classified locked hours, not adjusted settlement, not wages, no identities/raw events, self or organization scope with active membership and permission. Never enable on production. Legacy writes and exports stay blocked.
- Private bounded historical ingestion batches: validated tenant event IDs, ordered unique list, idempotent proposal, independent authorized approval, transactional all-or-nothing application and audit. No automated production ingestion or public write APIs.
- Authorization row mutation barriers on membership roles, tenant role grants, roles, delegations, team membership and approval steps. Critical candidate functions acquire tenant transaction lock before authorization. Platform role template changes remain privileged migration operations; hosted Auth session and all cross-tenant authorization races require independent review.
- Next: localized server review screen and native secure-store adapter. Browser stays memory-only. The native package must be pinned with verified npm integrity; no insecure storage fallback. CI will retrieve package metadata (no secret data). Native build/device testing remains required.

Validate npm run test:db, npm run verify, npm run build:web; actual preview screenshots where feasible. Independent Claude/equivalent review required for authorization, SQL grants, cross-tenant cache safety, accounting policy, secure storage and frontend responsiveness/accessibility. No real employee data, no production enablement. Accounting legal certification remains outstanding.
