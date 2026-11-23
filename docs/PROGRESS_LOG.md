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
