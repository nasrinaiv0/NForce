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

## 2026-11-23 — Sorting and custom filtering on every list

- **PR / issue:** #2.
- **Status:** Implemented and tested.
- **Summary:**
  - New shared filter model in `@nforce/core` (`collections/conditions.ts`). Operators depend on the column type (text, number, hours, percent, date, choice, yes/no), conditions can match all or any, incomplete conditions are ignored, and any column can be the sort key (choices sort in their natural order, such as urgent → low).
  - New `ListControls` / `useListView` UI: search, quick filter with counts, sort menu, a filter builder sheet, removable condition chips, and a saved view per list.
  - Tables sort by tapping column headers. Timesheet totals follow the visible rows when filtered.
  - Applied to every list: approvals, my requests, team, people, Work Center, attendance (people, exceptions, by team), executive team comparison, payroll, administration (members, audit, holidays, permission matrix), CRM (KPIs follow the filters), notifications, timesheet days, schedule week and team roster, and profile direct reports and leave history. CRM, notifications, timesheet, schedule, profile and the permission matrix had no sorting or filtering before.
  - Removed the old combined toolbar component.
- **Validation performed (2026-11-23):**
  - `npm run typecheck` and `npm run lint` passed.
  - Core **159 tests** passed (12 new for conditions and sorting; branch coverage 91.2%).
  - App **151 tests** passed. 5 new tests run every list's fields against real demo data: every field sorts both ways, every operator runs, data values match, and every choice value is offered.
  - In Chromium, on the team list, two custom conditions ("This week ≥ 8h", "Role is any of Staff") filtered 11 people to 6, showed as chips, and survived a page reload. Tapping the "Worked" header sorted the timesheet. No page errors.
- **Found by tests:** "is not" was missing for hour (duration) columns; added.

## 2026-11-23 — Live mode: Supabase Auth, workspaces and the live data client

- **PR / issue:** #2.
- **Status:** Implemented and tested against a simulated Supabase client. **Not yet verified against the hosted project**: access is still pending, and the database migrations are not applied there.
- **Summary:**
  - Sign in, create account (with email confirmation), password reset and sign out with Supabase Auth.
  - Workspace setup for new accounts; workspace switcher under More → Account; demo still one tap away.
  - Live data client (`liveDataset.ts`, `liveApi.ts`). Database rows are paged and mapped into the same snapshot the demo backend uses, so every screen works unchanged. Writes go through the database functions with matching arguments, and database errors map to app error codes.
  - The demo backend can now compute from a supplied dataset; demo behavior is unchanged (all earlier tests pass).
  - Leave types now come from the API. Adding an employee in live mode asks for their NForce account email.
  - Configuration through `EXPO_PUBLIC_SUPABASE_URL` / `EXPO_PUBLIC_SUPABASE_KEY` (`apps/mobile/.env.example`). Without them, the app runs the demo.
- **Bugs found and fixed during this work:**
  - The guarded home route rendered a blank page on first load instead of redirecting to sign-in. Fixed with an explicit redirect.
  - The More screen looped forever in demo mode: a selector returned a new empty array on each read (React error #185). Fixed.
- **Validation performed (2026-11-23):**
  - `npm run typecheck` and `npm run lint` passed.
  - Core 147 tests passed; app **146 tests** passed (14 new live-client tests covering row mapping, error mapping, 2,500-row paging, and the arguments of every write).
  - `./scripts/test-db.sh`: 162 SQL assertions passed.
  - The web build with live configuration redirected to sign-in, switched to the demo, and showed the account entry on More, with no page errors. The build without configuration still runs the demo.
  - Expo's online dependency check could not reach Expo's servers; the offline check reports dependencies up to date.
- **Blockers:** The Supabase token saved for `api.supabase.com` is rejected ("JWT could not be decoded"), and the Supabase connector's account cannot see project `jnhvceaotcphzvmwptdf`. Running a local Supabase stand-in (downloaded PostgREST/GoTrue binaries) was not permitted in this session.
- **Next steps:** With access, apply migrations 1–6 to the project, read the publishable key, set it in Vercel, then verify sign-up → workspace → clock in → request → approval end to end.

## 2026-11-23 — Timesheet table, schedule views, employee profile, live-app database layer

- **PR / issue:** #2.
- **Status:** Implemented. UI, backend and SQL tested. Not yet connected to the Supabase project (see Blockers).
- **Summary:**
  - **Timesheet** is now a table: in/out, breaks, worked, regular, OT and approved OT, night differential, paid-hour equivalent, and a totals row. Days with unfiled overtime are highlighted and offer "File OT".
  - **Schedule** now has three views:
    - Day: the existing detail view.
    - Week: a table of your own week. People who can see others' schedules can switch to a team roster (people × days, with leave and holidays).
    - Month: a calendar.
    - New `teamSchedule` endpoint, limited to people the viewer may see.
  - **Employee profile** redesigned. On desktop, profile and details are on the left, detailed information on the right, direct reports below. New employee information, each part behind its own access rule:
    - leave credits (available, used, pending) and recent leave requests;
    - 30-day attendance and overtime this month;
    - confidential employment details, personal and emergency contact, and masked government IDs (person, HR and owners only).
  - **Migration 6 (`20261128000000_live_app_backend.sql`)** adds what the live app needs:
    - sign-up profiles, and `create_organization` (the creator becomes owner; leave types, balances and Philippine holidays are seeded);
    - `add_member_by_email`, `update_member_details`, and per-member work patterns with `set_member_schedule`;
    - Work Center tasks with row-level security;
    - `my_workspaces` and `org_directory`;
    - approved corrections now write the corrected clock-out.
- **Also fixed:** a test bug where "anonymous" SQL checks still carried the previous user's ID.
- **Validation performed (2026-11-23):**
  - `npm run typecheck` and `npm run lint` passed.
  - Core **147 tests** passed; app **132 tests** passed (7 new profile-access tests).
  - `./scripts/test-db.sh` on PostgreSQL 16.15 applied 6 migrations; **162 SQL assertions** passed (31 new).
  - Timesheet, schedule (week, roster, month) and profile screens rendered in Chromium at desktop and phone sizes with no page errors.
- **Blockers:** Supabase project `jnhvceaotcphzvmwptdf` is not visible to the connected Supabase account. The access token saved for the Management API is rejected ("JWT could not be decoded"), so it is not a valid personal access token. Migrations are not applied there yet, and the app is not yet wired to it.
- **Next steps:** With a valid token or connector access: apply migrations 1–6 to the project, read its publishable key, add Supabase Auth sign-in and the live data client, and verify end to end.

## 2026-11-23 — Hierarchy and organization access hardening

- **PR / issue:** #2.
- **Phase/module:** Access model (all modules).
- **Status:** Implemented. Unit-, SQL- and render-verified. Not verified on devices.
- **Audit findings, now fixed:**
  1. Executives could approve time off and timesheets for anyone in the organization, and could not approve their own managers' attendance corrections (those got stuck). Approvals are now scoped to their reporting line, including corrections.
  2. The database accepted a decision from anyone named on a step, even after they lost approval rights. `decide_request` now re-checks the permission.
  3. Requests stayed with approvers who had been offboarded, moved or demoted. Pending requests are now re-routed after every organization change. A departed person's own pending requests are cancelled.
  4. The owner (top of the organization) could not file requests. These now route to another owner; a sole owner gets a clear explanation.
  5. HR could demote executives and managers (removing access HR doesn't hold) and could act on owners. Role changes now require holding both the current and the new role's access. Only owners manage owners.
  6. There was no database function to change a reporting line or department. Added `update_member`: same organization, active manager, no loops, no self-changes.
  7. An offboarded person kept access in the demo backend. Their membership now ends and every endpoint refuses them.
  8. The home team summary showed organization-wide counts to supervisors with no reports. Now only roles with organization-wide team reports get those counts.
  9. Correction requests were visible with `timesheet.view` in SQL but `attendance.view` in the app. SQL now uses `attendance.view`.
  10. Screens offered Edit/Offboard based on global capabilities. Each profile now carries the viewer's exact rights for that person.
- **Also fixed:** A SQL reporting test failed after 16:00 UTC because it used the server date instead of the organization's local date (Manila).
- **Validation performed (2026-11-23):**
  - `npm run typecheck` and `npm run lint` passed.
  - Core **147 tests** passed (lines 99.8%, branches 91.7%). These include exhaustive checks over a 12-person organization: every approver of every person is authorized for every request kind, nobody outside a person's reporting line (other than owners) can approve for them, and nobody can approve for themselves.
  - App **125 tests** passed, including all 9 personas through the real endpoints.
  - `./scripts/test-db.sh` on PostgreSQL 16.15 applied 5 migrations; **131 SQL assertions** passed (43 new).
  - Web build rendered in Chromium for HR, Owner, Manager and Executive with no page errors.
- **Known gaps:** Same as the previous entry (no real auth/Supabase client, in-memory demo data, not device-tested). The demo has one owner, so the owner persona sees a "nobody can approve your requests" message until a second owner is added.

## 2026-11-23 — Vercel web deployment configuration

- **PR / issue:** #2.
- **Status:** Implemented and verified locally. Not yet verified on Vercel at the time of writing.
- **Summary:** Vercel deployments returned 404 because the project had no framework or build settings. It published the repository root, which has no `index.html` (the build log shows no install and an 84 ms "build"). Added `vercel.json`: `npm ci`, `npm run build:web` (Expo web export of `apps/mobile`), output `apps/mobile/dist`, a fallback to `index.html` so deep links work in the single-page app, and long-lived caching for hashed bundles.
- **Validation performed:** `npm run build:web` exported `apps/mobile/dist`. Served it with an index fallback; `/` and `/more/attendance` rendered in Chromium with no page errors.
- **Known gaps:** The production domain deploys from `main`, so it shows the app only after PR #2 is merged. Preview URLs are behind Vercel authentication (the project's deployment protection setting).

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

## 2026-11-24 — P0 staging safety containment

- **Status:** Implemented for review; exact-head CI and isolated hosted acceptance pending. No remote migration, production configuration or merge authorized.
- **Scope:** Preserve demo; contain unverified live accounting writes and tighten credential/session handling, client mode selection and hosting headers. This is a safety gate, not payroll certification.
- **Validation plan:** Run existing CI, SQL denial assertions, browser and device acceptance with fictional tenants. Native secure persistence, historical roster/pay policy, server reconciliation, branch protection and independent review remain release gates. See [P0 acceptance plan](release/p0-acceptance.md).

- **CI iteration:** initial head `4c49eda9` applied the disposable migrations but failed the SQL test parser at workforce_access.test.sql:93. Corrected dollar-quoted test delimiters. Replacement-head CI pending; no remote SQL.

## 2026-11-24 — P0.2 private accounting candidate

- **Status:** Implementation staged; exact-head validation pending. Based on PR #3 7ce31805b417284da51815f36b0fdb56a1063c44. No production change or remote SQL.
- **Scope:** Sealed historical roster manifest, server punch replay and OT reconciliation, private timesheet submission via existing approval chain, atomic payroll lock with immutable evidence; retain public release gates. See [P0.2 design and acceptance](release/p0-2-accounting.md).
- **Validation plan:** Disposable SQL fixture and all existing CI, preview build, independent accounting/security review. Known gaps: authoritative roster import/lifecycle, premium pay codes, correction/adjustment policy, native acceptance and contention tests.

## 2026-11-24 — PH statutory compliance P1

- Status: planning recorded before code commit; candidate only. Stacked on PR #4 0384bfa8372ae5934536f55c65b3987bc2286d72; parent CI and preview builds passed. See [gap register](release/ph-payroll-compliance-register.md).
- Scope: private exact NUMERIC taxable-compensation arithmetic, official BIR Annex E periodic and TRAIN annual tables, date and input guards, disposable SQL fixtures. No public RPC, UI, gross-to-net, payment or remote migration. Daily upper bracket intentionally fails closed because source is malformed.
- Validation plan: SQL boundaries, rounding, invalid inputs and privileges in throwaway DB CI; independent CPA confirmation and isolated hosted acceptance pending. Full source tree and legal review remain incomplete. No merges or production change.

## 2026-11-24 — PH contribution arithmetic candidate (stacked after P1)

- Status: documented before implementation; candidate only. Base PR #5 7e61b4ee3183e0847bd2adcd71b4fbc4eb4f81d8, exact-head CI pending at planning time. No remote migrations, production changes, payment, public RPC or merge.
- Scope: GOV-01/04/07 arithmetic primitives only. Separate monthly agency-specific classified inputs for ordinary covered private business employees; no gross-to-net, deduction allocation, remittance, eligibility or legal certification. Positive two-decimal amounts only; zero/nonstandard circumstances require reconciliation. SSS 2024-006 (Jan 2025 onwards): all 61 MSC brackets, regular/MPF employee and employer shares, EC employer only. Source table visually checked https://www.sss.gov.ph/wp-content/uploads/2024/12/CI-2024-006-Publication.pdf . Pag-IBIG Circular 460 (Feb 2024 onwards): 1%/2% employee, 2% employer, 10k fund salary cap; official signed circular attached at https://dmw.gov.ph/archives/v1/resources/dsms/DMW/ISN-EXT/2025/DMW-ADVISORY-37-2025.pdf . PhilHealth Advisory 2025-0002 https://www.philhealth.gov.ph/advisories/2025/PA2025-0002.pdf : 5% premium, 10k/100k monthly basic salary, exclude overtime/allowances and do not reduce MBS for absences. For this candidate restrict PhilHealth to CY2025 pending independent confirmation of 2026 rules. Odd cent allocation follows historical PhilHealth example (employee lower half, ER remainder) https://www.philhealth.gov.ph/news/2018/sample_compu.html ; CPA must validate current rounding.
- Validation: all bracket lower/upper boundaries, caps, 1500 threshold, odd-cent allocation, invalid date/zero/nonfinite inputs, no API role grants; isolated SQL CI pending. CPA/legal must confirm coverage, updated issuances and month allocation, multiple employers, benefit and no-pay cases before any live integration. See existing gap register; GOV rows remain partial until complete evidence. Independent security and frontend reviews unchanged.

## 2026-11-24 — PH historical employment and compensation candidate
- Plan recorded before implementation. Base PR #6 f7c4eb710b045acaceeaa82447747a9af505aa04; exact-head CI success, Vercel READY. No remote SQL or production changes.
- HR-01–04 / LAB-05: private append-only, effective-dated full employment/compensation snapshots scoped to organization and membership, explicit separated state, rehire and wage/site evidence, as-of lookup by date and recording cutoff; reject missing records instead of inferring from current membership. No public access or live payroll connection. Corrections and authorized lifecycle importer remain separate gates. Store rate basis and numeric PHP, never infer daily divisor or minimum-wage coverage from salary amount. RLS and grants deny API roles. Source: Labor Code, https://dole.gov.ph/book-3-conditions-of-employment/ and NWPC https://nwpc.dole.gov.ph/ .
- Acceptance: isolated SQL lifecycle, effective-date and knowledge-cutoff tests, immutable rows, tenant scope, missing history, grants; CPA/labor review classification/divisors, security review importer and PII, Claude review existing HR UI and accessibility after integration. No merges.

## 2026-11-24 — PH exact compensable interval segmentation candidate
- Plan before implementation; base PR #7 71e2f68d8cb1f91afffb4a52e1910ac87b98c48a. LAB-01–04: ordinary covered employees, explicit attested workday (24h, Asia/Manila), exact compensable intervals (breaks already classified), split at midnight, 06:00, 22:00, and 8 cumulative hours; rest/holiday categories supplied per local date from reviewed policy; no rounding or minimum OT block or approval filter. No public execution or change to PR4 private candidate: live gates stay closed until trusted event replay, correction and holiday registry integration. Source: Labor Code Arts 84,86–88,93–94 https://dole.gov.ph/book-3-conditions-of-employment/ ; implementing rules https://lawphil.net/statutes/repacts/ra1989/omnibus_labor_1989.html . Ordinary covered work only; special workweek/exempt classes excluded. CPA/labor validate workday anchors, cross-midnight holiday/rest attribution and company-favorable rates. Security verify authoritative evidence, bounded inputs, no grants. Claude review existing timesheet UI, compact labels, accessible mobile/desktop and reduced motion when integrated. SQL fictional precision and boundary tests only. No remote migration or production changes.

## 2026-11-24 — PH compensation classification, benefit buckets and annualization candidate
- Plan before code; base PR #8 8ac4529e5f837e3f48a83026eb4655f88c07e8ad. BIR-07–16,18–20: private rank-and-file only classification and deterministic benefit-bucket transitions from attested opening balances; 2026-01-06 through 2026-11-24 only for new de minimis ceilings, older benefits need reviewed opening data. Source RR 29-2025 https://bir-cdn.bir.gov.ph/BIR/pdf/RR%20No.%2029-2025.pdf ; RMC 50-2018 https://bir-cdn.bir.gov.ph/local/pdf/RMC%20No%2050-2018.pdf ; RR 11-2018 https://bir-cdn.bir.gov.ph/local/pdf/RR%20No.%2011-2018.pdf pp 22–23,34–35. MWE eligibility and qualifying hazard pay must be attested with wage order and assignment evidence; no inference from salary or tax threshold. Other taxable earnings remain taxable. Excess qualified de minimis and qualifying other benefits share 90k yearly cap. Dependents medical monthly OR semester mode must be selected consistently for year. Vacation conversion measured in days (uniform rate per event); meals require approved regional wage basis. Unsupported codes fail closed. No client authority, persistent ledger, duplicate-event handling or production integration; opening history, dates, classification and evidence must be validated by future importer. Annualization uses present and successive previous employer taxable compensation and withheld tax, final pay availability, deficiency, employer advance and refund due date; no automatic payment. Year-end computation as simulation within rule verification date; future-year dates require rule approval. CPA validate caps, rounding, Jan 1–5 transition, 2316 evidence and refund deadlines; legal validate MWE/hazard eligibility; security verify trust boundaries and grants; Claude review payslip clarity and accessibility after UI integration. Disposable SQL only.

## 2026-11-24 — PH integration candidate (before implementation)
- Base PR #10 1bc1b4fe0c4f1eaf08a7e66b76728db9aecc4ec5; PR #9 31b4e0c06273b919d4f7faa16f14f5b9a63f6893 inspected, both CI and Vercel READY. Selectively port #9 adjustment and independent-connection lock regression rather than merge; unique migration versions 20261206+; retain one canonical ph_employment_history with independent shift/workday facts, no second eligibility table. Preserve exact seconds and calendar/night/OT segmentation; legacy P0.2 hours review/lock remains private and may block reconciliation (never silently drop unapproved OT). No new public grants. Do not apply remote SQL or merge.
- Benefit ledger: immutable tenant/employee/year opening state with reviewed evidence; per-year serialization and idempotency, chronological events, shared bucket and other-benefit consumption, fixed medical mode, reject unsupported dates/retroactive events. Form 2316 private structured transcription with dual review, identity evidence, source hash and issuer/pay-period reconciliation; use present-employer-only fields 21/25A, not cumulative 23/26; no PERA or concurrent employers support until reviewed; no automatic authenticity claim or PDF upload. Annualization reads approved prior employer totals. Independent CPA review of eligibility, opening balances, Form 2316 source, caps, refunds; labor review workday, break and wage assumptions; security review grants, tenant scoping, document storage, data retention; Claude review responsive frontend before integration. Source: BIR Form 2316 Sept 2021 ENCS https://bir-cdn.bir.gov.ph/local/pdf/2316%20Sep%202021%20ENCS_Final_corrected.pdf ; RR 11-2018 https://bir-cdn.bir.gov.ph/local/pdf/RR%20No.%2011-2018.pdf ; RR 29-2025 https://bir-cdn.bir.gov.ph/BIR/pdf/RR%20No.%2029-2025.pdf ; Labor Code Arts 84,86–88,93–94 https://dole.gov.ph/book-3-conditions-of-employment/ . All acceptance fictional, throwaway DB CI; no hosted acceptance, no paid resources, no production.

- CI iteration: PR #12 initial head 301451ed failed disposable migration parsing because the opening-bucket regex replacement corrupted the SQL string and duplicated the suffix. Restore the original migration content, reapply scoped validation with literal replacement, verify function count and rerun CI. Seven independent Python Decimal/time arithmetic assertions passed; no remote SQL.

- Replacement head 7fde286c passed disposable database/RLS tests (run 45309300192), including integrated exact payLines, benefit events, prior-employer 2316 totals and two independent lock transactions; app/Vercel checks not complete when recorded. Before further changes: preserve PR9 roster automation by adding shift-only and site-calendar revisions, authorized private imports and a canonical materializer that reads ph_employment_history and binds exact source revisions. Missing historical coverage, changed/overlapping workday, and unsupported policy fail closed; no second eligibility history or silent inference from current memberships. Extend deterministic fixtures for all 32 minimum premium combinations, private grants and cross-tenant denial. Parallel PR #11 3f0aca6242ceca432958ee971b36a82d62778365 (lifecycle/tenant locking) is outside this integration scope; do not merge it or claim its improvements. Independent review of combined lifecycle lineage remains required. No remote SQL.

- CI run 45309647889 (6c8797db): SQL fixture parser rejected reserved alias `both` in premium factor comparison; change alias to `combined_rate` without changing rates or assertions. Re-run exact-head CI. No remote SQL.

## 2026-11-24 — PH monetary payroll staging candidate (plan before code)
- Base PR #12 1c17beb4c9f6a0af8a1a7e40ca0e9f208cc08a68, PR #11 3f0aca6242ceca432958ee971b36a82d62778365, both exact-head CI and preview READY. Selectively port departed employee dual control, lifecycle observation (no inferred effective date), locked correction guard and tenant transaction barriers; do not import duplicate histories or migration prefixes. Use canonical evidence. Preserve public gates. No remote migrations, production or merge.
- BIR RR 11-2018 pp30–33: cumulative average uses related payroll periods, previous employer taxable/withheld, periodic tax table, nonnegative current deficiency, sticky selection; year-end/termination separate annualization. Source https://bir-cdn.bir.gov.ph/local/pdf/RR%20No.%2011-2018.pdf. DOLE handbook 2024 pp9–12: 365 equivalent days for genuinely monthly-paid staff, leap-day nuance, company favorable terms; no universal divisor. https://nwpc.dole.gov.ph/wp-content/uploads/2024/11/Workers-Statutory-Monetary-Benefits-Handbook-2024-Edition.pdf. Stage monthly full-paid non-MWE ordinary employee only, CY2025 Jan–Nov (PhilHealth candidate supported year, December annualization separate); no partial salary, benefit or other unsupported earnings. Dual-reviewed monthly basis/context, fixed historical divisor evidence, locked weekly exact seconds and premium increments (base salary already covers first eight hours), no silent adjustment or missing coverage. Agency-specific bases attested; monthly uniqueness, balanced journal and immutable snapshot. Previous employer input only reviewed Form 2316 with bound encrypted document custody. Custody metadata and encrypted bytes private; external trusted encryption/identity/signature verification/key management remain gates; never put plaintext or keys in repo. Use fake data only.
- Test numeric and authority boundaries, idempotency, locks, cross-tenant, no public grants, CPA/legal/security and Claude review (not executed). No release claim. New migration prefixes 20261209+; verify duplicate guard. Hosted/browser and real-device acceptance remain pending.

- Before further implementation: PR11 UI base blobs match PR12, port localized accounting gate without enabling live results. Add server-only Node AES-256-GCM helper with randomized IV, authenticated org/employee/import binding, source and envelope SHA256, strict bounds and tamper tests. Caller supplies key from approved future key provider; no committed key, hosted vault or upload/download route. Fictional fixture only. Python Decimal reference: 30000 basic + 308.22 premium, 2475 EE, 4030 ER, 1050.03 tax, 26783.19 net, 34338.22 cost; cumulative cases checked. SQL and app CI not yet run.

- Initial PR #15 run 45311749060: disposable migration parsing failed at cumulative CASE in IF expression. Parenthesize CASE as numeric comparison operand without altering calculation or tests; rerun exact-head CI. No remote SQL.

- Replacement bda64d2d disposable SQL passed (run 45311810127), including exact gross-to-net, journal, departed path, custody metadata, payroll-lock, benefit and cross-tenant races. Before final verification: extract monthly fixture for independent concurrent monetary posting, require one snapshot/journal/audit event, and prevent minute adjustments after monetary posting pending authorized monetary reversal. The fixture directly seeds locked evidence only for isolated monetary test; attendance replay is exercised by PR12 regression. No remote SQL.

- Run 45312039379 (cd458416): independent-session seed failed independent-review check because fixture ran in autocommit, so transaction-local JWT claim reset before review. Run fixture in one explicit psql transaction (-1); keep distinct actor assertion and all guards unchanged. Recheck replacement head; disposable database only.

## 2026-11-24 — Statutory expansion (plan before code)
- PR15 21f0bf4d6a1a611a98e07a5815bfb737d96c8369 CI green, Vercel queued at initial inspection. Open PRs 3–16 inventoried; #13 secure ingestion/native session, #14 canonical integration and browser acceptance, #16 030baba48fad6b874bf75a494dfc35fff13d1b2f weekly monetary model/custody overlap with #15. Do not import parallel tables/migrations or combine lineages; retain #15 canonical journal/custody and PR12 benefit ledger. #16 adds separate ph_salary_divisor_evidence/ph_monetary_opening/ph_monetary_snapshot/ph_payroll_journal and conflicting ph_2316_custody. Future single-lineage selection required. No merges.
- Extend existing contribution calculator only for verified months Jan–Nov 2026; government PIA May 14 2026 https://pia.gov.ph/news/philhealth-sets-5-premium-contribution-rate-for-2026/ and signed PA2026-0042 https://www.philhealth.gov.ph/advisories/2026/PA2026-0042.pdf confirm 5%, floor 10k ceiling 100k shared equally. SSS Circular 2024-006 and HDMF 460 remain applicable. Preserve 2025 calculations and reject unverified future months. BIR Annex E 2023 onwards; ambiguous daily top band stays blocked. Daily/semi-monthly gross-to-net candidate with explicit independently attested regular/qualifying MWE vs taxable components, monthly contribution allocation and taxable deduction evidence, benefit ledger references; read-only quote, no second posting model. RR29-2025 effective-date guard preserved; no December extrapolation. DOLE LA21-26, RA11210/DA01-19/RMC105-2019, Art95, RA8187, RA11861, RA9262, RA9710, Arts298–299 and RA7641: stage deterministic minimum benefit calculations with reviewed eligibility/inputs; do not infer full eligibility or replace more favorable terms. Separate dual-controlled reversal of unsent accrual, exact inverse of canonical #15 journal, one reversal, no automatic repayment/filing/repost; block later same-year snapshots until reviewed replay. No remote migrations, real data, paid resources, production changes. Tests in disposable CI; Python Decimal independent fixture check. Independent CPA/legal/security/Claude review and browser acceptance remain gates.

- PR18 initial head cb301164 database CI passed (45312981689): three official DOLE 2026 examples, 93 contribution installment reconciliations, MWE daily/semi-monthly ledger quotes, inverse journal and concurrent reversal. Eight independent Python Decimal assertions passed. App and Vercel still pending when recorded. PR17 discovered concurrently, head 8cb4e233c859eea8f70c18eb51bb72c720b6a94e, stacked #16: ph_payroll_attestation, decisions, 2026 weekly monetary posting, annual settlement, contribution replacement, custody retrieval and a second Node envelope helper. Migration version 20261206000000 conflicts with #12. Selectively reconcile after explicit architecture acceptance; no duplicate implementation or merge. Before further test commit: add non-MWE quotation and tenant denial checks. No remote SQL, production changes or real records.

## 2026-11-24 — P0.9 consolidation (before implementation)
- Base #18 cee8bca6db6db8ad92a4278f214c34ac32c9161f; #15 21f0bf4d6a1a611a98e07a5815bfb737d96c8369 CI/preview green, #18 CI green preview queued, #17 8cb4e233c859eea8f70c18eb51bb72c720b6a94e SQL/app/export green browser pending. Reviewed open PR inventory #3–18, #13 secure native session/role barriers, #14 exact-second aggregate UI/browser, #16 duplicate weekly money/custody, #17 evidence/annual settlement. Choose #18 base; selectively port session and role barriers, read-only aggregate/browser, custody retrieval (existing AES-GCM only), authenticated evidence patterns, reuse canonical snapshot/journal/benefit/custody rather than create second monetary tables. No merge, no remote SQL, no paid resources or production change. New migration versions beyond 20261214000000. Private functions, disabled public review window (no seed), no live posting grants.
- Official NWPC current summary Nov6 https://nwpc.dole.gov.ph/wp-content/uploads/2026/11/4-Summary-of-Current-Regl-MWRs-Non-Agri-and-Agri-by-Region-November-6_2026.pdf plus current regional pages and later orders (XI-24 two tranches; XII-26 Nov22); NIR transitional VI/VII jurisdiction, not one uniform wage; https://nwpc.dole.gov.ph/region-nir/ . Registry supports all regions, locality/sector/size/effective interval, explicit source/hash and reviewer; no unsupported automated wage selection or completeness assertion. BIR Annex E https://bir-cdn.bir.gov.ph/local/pdf/Annex%20E%20RR%2011-2018.pdf visual confirmation malformed daily top band, retain guard. DOLE LA21-26 and existing statutory sources; no future periods. Ordinary covered candidate only: fixed frequency, contiguous period ledger, reviewed wage/period/agency evidence, immutable locked seconds, ledger benefit consumption, no cross-period spill without reviewed allocation; no inferred exclusions or actual payment. Preserve legacy 2025 fixtures; one canonical financial ledger. Annual/final settlement and correction replay need explicit completeness, signed documents, and journal consistency; fail closed on unsupported cases rather than claim full coverage. Independent CPA/legal/security/Claude acceptance required. Test fictional data only; capture browser screenshots if isolated CI supports. Document gaps and exact-head results honestly.

- P0.9 implementation so far: port #13/#14 session/review files and role mutation barrier, private exact-second review RPC remains disabled without acceptance grant; port isolated browser/native JS exports preserving PR15 crypto tests. New evidence tables and four-frequency 2026 candidate share ph_money_snapshot/ph_money_journal, with conditional legacy FK and 2026 reviewed attestation binding. Scope: Jan6–Nov24 paid on cutoff end, daily/hourly basis or genuinely monthly-paid on monthly/semi-monthly only, exact locked days, reviewed zero-work disposition, fixed frequency, approved wage/category, one contribution allocation per month, benefit keys, verified prior certificates and tax-deduction classification. No production activation. Before next code: stage immutable annual/termination tax adjustment journal from effective snapshots (no future year-end posting, legal final pay components still separate); correction replay only of latest reversed and undispatched 2026 accrual with reviewed supplemental correction, not settled payment or arbitrary backdate; reuse same computation where safe. Add fictional reference fixtures and maintain old regression. Explicitly record unsupported scenarios rather than claim full completion.

- PR21 initial head de9e705a, CI 45314339092: SQL parser rejected collapsed dollar delimiters in the two thin posting/replay SQL wrappers (JavaScript replacement expansion). Restore paired dollar quotes literally; leave calculation/guards unchanged. Six independent Decimal assertions passed. Recheck exact replacement head. No remote SQL.
