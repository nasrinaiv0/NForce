# P0.4 enterprise lifecycle candidate

Stacked on PR #9 at 31b4e0c06273b919d4f7faa16f14f5b9a63f6893. No remote migrations or production changes; public payroll gates remain closed.

- Capture membership and shift changes as immutable observed events. Private ingestion resolves them against an explicit historical timezone policy (creation day, changes next local day). No synthetic backfill; same-day conflicts and missing baselines fail closed. Trusted operator ingestion, reconciliation and coverage attestation still required.
- Replace global accounting table locks with tenant-keyed transaction locks. Row triggers reject same-tenant contention with SQLSTATE 40001; retry whole transaction. Hash collisions may serialize unrelated tenants. Authorization writes, other unguarded write paths and load/deadlock tests require independent review before activation.
- Block direct punch corrections to locked historical weeks, conservatively including next local day; use existing dual-control adjustment ledger. No wage or correction-UI activation.
- Next commit: departed employee dual control and regression tests, localized release gate. No public activation.

Validate in disposable CI only: npm run test:db, npm run verify, npm run build:web. Independent Claude or equivalent review required for lock protocol, authorization, history completeness, payroll legality, responsive UI, spacing, fonts, buttons and accessibility. No real employee data, no production merges or migrations.

## Second commit
Departed employee review and approval are distinct private actions with current permissions, exact recalculation, immutable evidence, and no restored login. Existing submitted/approved sheets require review; versioned review replacement is not yet implemented. New SQL regressions cover capture, ingestion, offboarding and correction guard. Independent tenant lock test uses the existing disposable local CI database. Live timesheet/payroll views show a localized release notice rather than unverified results; query hooks remain mounted. Demo remains unchanged. Actual rendered browser acceptance, broader authorization races and enterprise load tests remain outstanding.
