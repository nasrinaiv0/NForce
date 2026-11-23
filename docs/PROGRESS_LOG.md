# NForce Development Progress Log

This log records meaningful project progress. Update it in the same pull request as each implementation or architecture change. See [Development Progress & Documentation Policy](./DEVELOPMENT_PROGRESS_POLICY.md).

## 2026-11-02 — Enterprise workforce architecture baseline

- **PR:** [#1 — Enterprise workforce architecture and mandatory progress tracking](https://github.com/nasrinaiv0/NForce/pull/1)
- **Phase/module:** Product architecture and delivery governance.
- **Status:** Architecture proposed; no application features implemented by this documentation change.
- **Summary:** Established a proposed enterprise workforce platform architecture covering multi-tenant organization structure, role-aware workspaces, RBAC + ABAC, tenant isolation, attendance, shifts, timesheets, leave/day-off requests, Work Center, HR, payroll integration, CRM, operations, analytics, automation, security, accessibility, motion and delivery phases.
- **Files/systems affected:** `README.md`, `docs/architecture/enterprise-workforce-platform.md`, `docs/DEVELOPMENT_PROGRESS_POLICY.md`, `docs/PROGRESS_LOG.md`, `.github/pull_request_template.md`.
- **Validation performed:** Documentation content authored and submitted for review. Application tests, type checks, security scans, builds, database migrations and deployment checks have **not** been run as part of this documentation-only change.
- **Security/data implications:** The proposed design requires server-side authorization, tenant-aware queries, PostgreSQL RLS, protected audit records, private document storage and cross-tenant access tests. These are design requirements, not verified implementation claims.
- **Known gaps/blockers:** Repository application structure and current implementation have not yet been audited. Product scope, target payroll jurisdictions, integrations, data-retention policies, and initial release scope need confirmation. No application code or production configuration was changed.
- **Next steps:** Review and approve the architecture; inspect the repository; agree Phase 1 acceptance criteria; implement tenant and authorization foundations; add tests and update this log in every meaningful implementation PR.

## 2026-11-23 — Phase 1 foundation: mobile app, domain core and database security

- **PR:** Not yet opened (branch `claude/vigilant-maxwell-mkbi61`).
- **Phase/module:** Phase 1 Foundation, with a Phase 2 workforce-core preview (attendance, schedule, timesheets, time off, approvals, Work Center).
- **Status:** Implemented. Unit-, SQL- and render-verified as listed below. Not verified on physical devices or simulators.
- **Summary:**
  - npm-workspaces monorepo with CI (`.github/workflows/ci.yml`).
  - `@nforce/core`: permission catalog and least-privilege role templates; `authorize()` with tenant, membership, scope, sensitive-data, locked-record and separation-of-duties checks plus time-boxed delegations; immutable attendance replay with idempotency, overnight shifts and exceptions; timesheet state machine with audited post-lock adjustments; leave vs day-off evaluation; task bucketing; DST-safe time utilities; permission-driven workspace composition.
  - `apps/mobile` (Expo SDK 58, React Native 0.88, Expo Router): native tab bar (iOS UITabBar / Android M3 NavigationBar), native stacks with iOS large titles, a dual iOS/Material 3 design system, light/dark mode, haptics, and en/fil/es localization. Screens: Home (role-aware widgets), Work, Clock, Schedule, More, Approvals, Timesheet, Time off, New task sheet, Request time-off modal with range calendar and live policy preview. Includes a branded icon set.
  - In-memory backend implementing the `NForceApi` contract through `@nforce/core` rules (switchable demo personas).
  - `supabase/migrations/20261123000000_foundation.sql`: organizations, departments, teams, memberships, permissions, roles, grants, delegations, attendance events, audit events. Composite same-tenant FKs, RLS on every table, immutable attendance/audit, idempotent `record_attendance_event()` RPC, and a seed generated from core.
  - Docs: mobile architecture, ADRs 001–005, award-readiness guide, architecture implementation map, README.
- **Files/systems affected:** `package.json`, `package-lock.json`, `.gitignore`, `.github/workflows/ci.yml`, `apps/mobile/**`, `packages/core/**`, `supabase/**`, `scripts/test-db.sh`, `README.md`, `docs/**`.
- **Validation performed (all run in the development container on 2026-11-23):**
  - `npm run typecheck` (core + mobile, strict) — passed, 0 errors.
  - `npm run lint` (Expo ESLint config incl. React Compiler rules, `--max-warnings 0`) — passed.
  - `npx vitest run --coverage` in `packages/core` — 56 tests passed; coverage 100% lines, ~99% statements, ~91% branches (thresholds 90/90/85/90 enforced).
  - `npx vitest run` in `apps/mobile` — 14 tests passed (translation parity/placeholders, Intl formatting, mock API rule enforcement).
  - `./scripts/test-db.sh` on PostgreSQL 16.15 — migration applied, 21 SQL security assertions passed (tenant isolation, scope-aware RLS, idempotent/validated clocking, immutability, delegation windows, anonymous denial).
  - `npx expo export --platform web` — production bundle built. It was rendered with Playwright at 393×852 in iOS and Android flavors, light and dark, for 9 screens, with no page or console errors. A scripted browser smoke test passed: start/end break updates status and activity; approving removes the request (5 → 4); switching to the Staff persona hides the Approvals module; switching to Filipino relabels the tabs.
  - **Not run:** iOS/Android simulators or devices, `expo-doctor` (network access to Expo services was unavailable), E2E tests, Supabase-hosted deployment.
- **Security/data/accessibility/performance implications:** Server-side enforcement is designed in (RLS + SECURITY DEFINER RPC with fixed `search_path`). The client never sets attendance timestamps. Accessibility labels/roles/states, font scaling, reduced motion and 44/48-pt targets are implemented, but there has been no assistive-technology audit on devices yet. React Compiler, native-driver animations and route code-splitting are enabled, but no on-device performance measurement yet.
- **Known gaps/blockers:** No authentication or live Supabase client (mock backend only). Timesheet/leave/approval SQL tables are not yet created. No offline outbox. No push notifications. People/Payroll/CRM/Reports/Admin screens are placeholders. The `supabase/tests` SQL is plain SQL run via `scripts/test-db.sh`, not pgTAP. Open decisions from architecture §16 still apply.
- **Next steps:** Supabase project + auth (Phase 1 completion); implement `NForceApi` over Supabase; Phase 2 SQL for timesheets/leave/approvals with RLS tests; offline clock outbox; Maestro E2E on both platforms; device accessibility audit; EAS build profiles.

## 2026-11-23 — Phase 2: hierarchy, approvals, pay categories, lists, desktop mode, customization, brand

- **PR / issue:** Not yet opened (branch `claude/vigilant-maxwell-mkbi61`).
- **Phase/module:** Phase 2 workforce core (attendance, timesheets, approvals, pay classification), app shell (desktop), design system (customization, brand).
- **Status:** Implemented. Unit-, SQL- and render-verified as listed below. Not verified on physical devices.
- **Summary:**
  - **Hierarchy & access:** reporting lines (`reports_to`, cycle-free, same tenant). Direct and indirect reports are team scope. Looking *up* the line requires organization scope, so managers can't see their own manager's data. The Team module is visible only with person-level attendance scope (supervisor: their line; manager: department; executive: aggregates only). HR views time off but no longer approves it; executives finalize managers' own requests (role templates re-synced via migration 2).
  - **Hierarchical approvals:** leave, day off, overtime, timesheet and correction requests route supervisor review → manager final approval. Managers can approve at any stage (review marked skipped), returns need a reason, and nobody approves their own request. Final decisions update balances, roster, timesheet status, approved OT and correction events, and are validated before commit. Implemented in `@nforce/core` `approvals/chain.ts`, SQL `submit_request` / `decide_request` with RLS, and the app.
  - **Pay categories:** classification into regular, OT, night differential (22:00–06:00), rest day, special non-working day, regular holiday and all combinations, with payroll codes and PH default multipliers (OT 125%, RD/SH 130%, RD OT 169%, SH on RD 150%, RH 200%, RH on RD 260%, ND +10%). Minimum OT block (default 30 min; shorter time is excess, not OT); per-day OT authorization against approved OT requests; holiday calendar table; "File OT" flow.
  - **Sorting, filtering, search:** shared `@nforce/core` `collections/query.ts` (stable locale-aware sort with missing values last; accent-insensitive multi-term search; facet counts), used by Approvals, Team, Work and Time off. The desktop Team view has sortable table headers.
  - **Desktop mode:** M3 window size classes; sidebar (expanded or icon rail) on web and large Android screens, with the native iPad sidebar; centered max-width content; two-column Home, Timesheet and Time off; card-grid Approvals; Team data table.
  - **Customization:** theme, 9 accent colors (default NForce teal with the logo's teal→navy gradient), density, platform look, sidebar style, Home layout (reorder and show/hide widgets, permission-safe). Preferences are schema-validated (storage key v2).
  - **Brand:** the user-supplied NForce logo is used for the app icon, Android adaptive icon (foreground, background, monochrome), splash, favicon and sidebar mark.
  - Localized en/fil/es for all new UI. Docs: mobile architecture §11–12, ADR-006/007, implementation map, README screenshots.
- **Files/systems affected:** `packages/core/src/{access,approvals,pay,collections,timesheet,workspace}`, `packages/core/test/*`, `supabase/migrations/20261124000000_hierarchy_approvals.sql`, `supabase/tests/hierarchy_approvals.test.sql`, `apps/mobile/src/**` (new: Team, Customize, Request overtime, Sidebar, ListToolbar, DataTable, PayBreakdown, accents/color), `apps/mobile/assets/**`, `docs/**`, `README.md`.
- **Validation performed (2026-11-23, development container):**
  - `npm run typecheck`: passed. `npm run lint` (`--max-warnings 0`): passed.
  - `packages/core` `vitest run --coverage`: **100 tests passed**; lines 99.8%, statements 98.8%, branches 91.8%, functions 96.9%. Includes hand-checked premium multipliers, overnight ND, OT into the night window, rest day/holiday, split shifts, DST fall-back, minimum OT block, approval routing/override/self-approval, upward-visibility denial, and SQL↔core role-seed parity.
  - `apps/mobile` `vitest run`: **61 tests passed**, including WCAG AA contrast for all 36 accent × flavor × scheme combinations, home-layout resolution, and the mock API hierarchy, approvals, OT, timesheet and correction flows.
  - `./scripts/test-db.sh` on PostgreSQL 16.15: both migrations applied; **42 SQL security assertions passed** (21 foundation + 21 hierarchy/approvals). During development these tests caught and drove fixes for RLS policy recursion between the approval tables, upward visibility through department scope, and a timesheet approval silently denied for lack of hierarchy context.
  - `npx expo export --platform web`: built. Playwright rendered 16 screens (phone iOS/Android, light/dark; desktop 1440×900) with no page or console errors. A scripted desktop flow passed: manager final approval (10 → 9 pending), Overtime filter (2 results), Team sort by weekly hours, accent and sidebar persistence.
  - **Not run:** iOS/Android simulators or devices, `expo-doctor` (Expo services unreachable), Supabase-hosted deployment, assistive-technology audit on devices.
- **Security/data/accessibility/performance implications:** Approval decisions and request creation are server-side RPCs with RLS. Requests and steps are read via a SECURITY DEFINER visibility check (avoids policy recursion), and all decisions are audited. Accent palettes are contrast-tested. Pay rules are PH defaults and **must be validated by payroll/legal professionals**.
- **Known gaps/blockers:** Pay outputs are hours × multipliers, not money or statutory contributions. Shifts are attributed to their start date (other attribution rules not yet configurable). Timesheet and leave-balance SQL tables are not yet created. Auth and the Supabase client are still mock. The logo source is a 451×484 JPEG, so a vector or high-res original is needed for store assets. Holiday list includes only statutory dates fixed by law (proclaimed dates must be added per year).
- **Next steps:** Supabase client + auth; timesheet and balance tables with RLS; payroll export using pay lines; configurable shift attribution and holiday-on-holiday rules; device QA and accessibility audit; EAS builds.

## 2026-11-23 — High-resolution logo and brand asset pipeline

- **PR / issue:** Not yet opened (branch `claude/vigilant-maxwell-mkbi61`).
- **Phase/module:** Brand / design system.
- **Status:** Implemented and render-verified.
- **Summary:** Replaced the 451 px logo with the 2048 px master supplied by the product owner (`design/brand/nforce-logo-master.jpg`). Added `scripts/generate-brand-assets.py`, which regenerates the iOS icon, Android adaptive icon (foreground, background and monochrome), splash, favicon and in-app logo. **Correction to the previous entry:** the earlier assets removed the background with a flood fill, which leaked through the opening where the N's leg meets the cube's edge and left the N transparent in the splash, Android foreground and sidebar logo. The pipeline now cuts along the cube silhouette (convex hull, 4× supersampled), so the N is solid white. The brand gradient and `nforce` accent now match the logo exactly (#3B929C → #1E385B). The Android adaptive-icon background and splash backgrounds were updated in `app.json`. README screenshots were refreshed.
- **Files/systems affected:** `apps/mobile/assets/**`, `apps/mobile/app.json`, `apps/mobile/src/design/accents.ts`, `scripts/generate-brand-assets.py`, `design/brand/nforce-logo-master.jpg`, `docs/architecture/mobile-app.md`, `docs/screenshots/*`.
- **Validation performed:** Generated assets inspected visually on white and dark backgrounds (N solid, clean edges). `npx tsc --noEmit` and `npx eslint . --max-warnings 0` passed. `npx vitest run test/customization.test.ts` passed (38 tests, including WCAG AA contrast for the updated brand accent across all flavors and schemes). The web bundle was rebuilt and 20 screens rendered with Playwright with no page errors.
- **Known gaps:** The master is a JPEG; a vector (SVG/PDF) original is still preferred for print and store marketing. Not checked on physical devices or launchers.
- **Next steps:** Add the vector master when available and re-run the generator.

## 2026-11-23 — Attendance & executive reports, all planned modules, owner access model, compact desktop Home

- **PR / issue:** Not yet opened (branch `claude/vigilant-maxwell-mkbi61`).
- **Phase/module:** Phases 3–6 (Work Center/Operations reporting, HR & Payroll, CRM, enterprise analytics/admin) and the access model.
- **Status:** Implemented. Unit-, SQL- and render-verified. Not verified on devices.
- **Summary:**
  - **Attendance for all** (self/team/org) and an **executive report** (KPIs with deltas, trends, labor mix, team comparison, approval SLA, leave utilization, payroll readiness, risks, CSV). Core: `reports/attendance.ts`, `reports/approvals.ts`, `export/csv.ts` (formula-injection safe). The demo backend now has 9 weeks of history.
  - **Modules replacing placeholders:** People (directory, profiles, confidential fields for self/HR only), Payroll (register by pay code with approved-OT-only payment, blockers, CSV, lock), Administration (permission matrix, members, audit log, holidays, pay rules), CRM (pipeline, weighted forecast), Notifications inbox, plus a notification bell.
  - **Access model v2:** Organization **Owner** with every permission and approval override; distinct HR, Payroll, Operations and IT admin templates; role assignment without privilege escalation; add/edit/offboard employees with report reassignment and last-owner protection. New demo person: Sofia Reyes (Owner).
  - **Desktop Home** redone as one compact, professional column (header + quick actions, summary strip, dense panels in the user's order).
  - **SQL:** migration 3 adds timesheets (immutable once locked), the leave ledger and balance view, payroll periods and the lock RPC, trigger-written notifications, CRM tables with the `move_deal` rules, and the aggregate-only `report_attendance_summary` (groups under 3 folded). Migration 4 adds the owner role and new permissions (role templates re-synced), request payload validation, the owner override in `decide_request`, and `assign_role` / `add_member` / `offboard_member`.
- **Corrections found by tests during this work:** leave requests without a leave type or day count could be submitted and could not post to the ledger, so payload validation was added in SQL. A local-variable shadowing bug in the backend report functions was fixed. Demo absences were too rare to be realistic (attendance showed 100%), so their frequency was tuned.
- **Validation performed (2026-11-23):** `npm run typecheck` passed; `npm run lint` passed (0 warnings); core **120 tests** passed (lines 99.8%, statements 99.0%, branches 91.9%, functions 98.0%); app **80 tests** passed; `./scripts/test-db.sh` on PostgreSQL 16.15 applied all 4 migrations and **88 SQL assertions** passed; the web bundle was built, 15 new screens were rendered with Playwright with no page errors, and scripted flows passed (owner final approval 11 → 10; HR offered only Staff/HR roles, added an employee, offboarded an employee; HR has no Payroll/Approvals navigation).
- **Known gaps:** Authentication and the Supabase client are still mock. No CRM editing UI. Employee invitations do not send email. Not tested on devices. Pay rules must be validated by payroll/legal.
- **Next steps:** Supabase client + auth; invitation flow; CRM editing for a sales role; device QA and accessibility audit; EAS builds.

## Future entry template

Copy and complete for each meaningful change:

### YYYY-MM-DD — Short change title

- **PR / issue:**
- **Phase/module:**
- **Status:** Planned / In Progress / Implemented / Verified / Blocked
- **Summary:**
- **Files/systems affected:**
- **Validation performed:** List commands/checks actually run and exact outcomes.
- **Security/data/accessibility/performance implications:**
- **Known gaps/blockers:**
- **Next steps:**
