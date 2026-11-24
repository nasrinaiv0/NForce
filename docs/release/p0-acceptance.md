# P0 staging acceptance — 2026-11-24

Base: `1e088109e6ef967b92528a2ff43eac7bcea9a3bb`. No production changes; no real employee records. Use throwaway PostgreSQL and an explicitly approved isolated Supabase environment only. No paid resources authorized.

## Scope and rationale

This PR implements conservative security containment. Live timesheet submission and payroll lock remain disabled until effective-dated employment/roster, historical timezone and pay policies, immutable corrections and server-calculated reconciliation are implemented and independently accepted. Do not replace this gate with current-roster estimates. Demo workflows remain available for fictional data. Session tokens are memory-only pending native Keychain/Keystore and browser session design; reload requires reauthentication. Web hardening is deliberately compatible with Expo export. Review effective deployment headers separately; CSP is baseline only, not a comprehensive XSS defense. If a deployment has old persisted tokens, revoke those sessions and remove legacy storage through a separately reviewed rollout. No secrets may be placed in public Expo variables.

## Acceptance matrix

| Gate | Expected |
| --- | --- |
| Fresh database | All migrations apply locally in order; legacy access tests still pass, new accounting denial tests pass. |
| Direct accounting RPC | Authenticated staff cannot submit timesheet; payroll/owner cannot lock; generic timesheet request also denied; no record created. |
| Demo | Clock, timesheet and payroll demo workflows still work; no network writes. |
| Live identity | No demo data on missing identity/workspace/config; no live data on demo routes. |
| Sessions | No newly persisted tokens; logout clears active session; reload requires sign-in. Inspect native storage and browser storage. |
| Security headers | Verify deployed responses, deep links and Expo asset loading; no framing; HTTPS. |
| Database platform trigger | Inspect installed function owner and event-trigger dependency; after authorized staging migration ensure anon/authenticated execution absent and newly created public tables still receive RLS. Never run this probe on production. |
| Future accounting | Verify historical eligibility for joiners/leavers, overnight and DST shifts, approved overtime/corrections, missing sheets, concurrent locks/submits, immutable locked records, pay-period reconciliation and audit trails. |

## Release controls

Do not merge until exact-head CI, isolated Auth/PostgREST acceptance and independent review are complete. Repository administrator must enforce branch protection/required CI and review. No production migrations until approved backup/restore and rollback rehearsal. Roll forward to a corrected migration; never silently restore unsafe accounting permissions or delete audit history. Existing production remains untouched.

Independent reviewer (Claude or equivalent, not yet run): inspect SQL grants/trigger behavior, bypass routes, historical accounting requirements, identity transitions, Expo session storage and headers. Review frontend messages, spacing, typography, touch targets, reduced motion, tablet responsiveness and performance; attach evidence. Obtain independent payroll/legal approval before enabling accounting.
