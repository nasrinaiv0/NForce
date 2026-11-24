# P0.2 accounting candidate — staging only

Base: 7ce31805b417284da51815f36b0fdb56a1063c44 (PR #3). Public accounting write gates remain closed. No remote migration or production deployment.

## Implemented design
- Private sealed weekly roster manifest, explicit historical eligible work dates, historical timezone and per-day thresholds with policy references. A trusted historical import and independent completeness attestation are required; current membership is not used to reconstruct history. No importer UI, employment lifecycle automation or legal policy certification yet.
- Reconcile immutable punches by clock-in local date; handle overnight, subtract breaks, reject invalid/open sessions, reject pending overtime/corrections, cap approved overtime at actual overtime, retain unpaid/excess minutes separately.
- Private candidate submit computes totals, writes existing timesheet and passes a one-use transaction ticket into existing authorized approval chain. Generic endpoint and legacy public submission remain closed.
- Private candidate lock serializes writes with conservative table locks, requires every historical eligible person (including zero-work) to have a matching approved submission and no unapproved OT, stores immutable reconciliation snapshots and audit record atomically. No public execute grants, including service_role. Global table locks are deliberately conservative and must be replaced with a proven tenant/period protocol before activation.
- Existing app demo remains unchanged. No new UI activation; server candidate is intentionally not reachable from the client.

## Remaining gates before live activation
1. Effective-dated membership/shift history automation and trusted roster importer with completeness reconciliation (including joiners/leavers, absences, rest days and terminations; no fabricated past data).
2. Offboarded staff submission/approval policy and authorized HR attestation workflow.
3. Premium pay-code and night/holiday/rest-day classification, historical pay policy, rounding, leave treatment and legal review. This candidate reconciles hours, not wages; no payroll exports based on it.
4. Corrections after lock must enter audited adjustment workflow; immutable snapshots remain unchanged. Define handling of pending cross-boundary corrections, duplicate OT requests, late approvals, DST and future edits; test adversarially.
5. Load/concurrency tests with separate connections, tenant isolation, role changes, rollback and race testing. Test actual hosted Supabase privileges only on approved isolated project.
6. Native/browser UI acceptance, secure persistence, branch protection, independent Claude or equivalent review; no merge or enablement until approval.

## Test instructions
Run `npm run verify`, `npm run test:db` (throwaway PostgreSQL only) and `npm run build:web`. Inspect PR exact-head checks. Render demo at phone/tablet/desktop and confirm payroll and timesheets remain explicitly gated in live mode. No real employee data. Independent reviewer should inspect SQL privileges, transactional ticket, roster completeness, attendance/correction edge cases, OT reconciliation, deadlocks, frontend responsive spacing/fonts/buttons/accessibility and reduced motion. No independent review has been run.
