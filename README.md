# NForce

NForce is an enterprise workforce platform with role-aware workspaces: attendance, schedules, timesheets, time off, a Work Center and approvals, with HR, payroll integrations, CRM and administration on the roadmap.

> **Current status (2026-11-23):** All modules in the architecture are implemented against an in-memory backend (attendance, scheduling, timesheets, time off, approvals, Work Center, people/HR, payroll preparation, CRM, reports, administration, notifications), with SQL migrations and tests for the data layer. Phase 1 foundation is implemented: a native iOS and Android app (Expo / React Native), a fully tested shared domain core, and a PostgreSQL/Supabase schema with row-level security. The app runs against an in-memory backend that enforces the real business rules. Authentication and the live Supabase client are not built yet. See the [progress log](docs/PROGRESS_LOG.md) for verified evidence and known gaps.

## What's inside

| Path | What it is |
| --- | --- |
| [`apps/mobile`](apps/mobile) | iOS and Android app: native tab bars and stacks, platform-adaptive design system (Apple HIG + Material 3), light/dark, English/Filipino/Spanish |
| [`packages/core`](packages/core) | `@nforce/core`: framework-free business rules (authorization, attendance, timesheets, leave, work, time), 100% line coverage |
| [`supabase`](supabase) | Migrations (tenancy, RBAC + ABAC, RLS, immutable attendance, idempotent clock RPC) and SQL security tests |
| [`scripts/test-db.sh`](scripts/test-db.sh) | Runs migrations + SQL tests on a throwaway PostgreSQL |

## Quick start

```bash
npm install
npm run start        # Expo dev server (press i for iOS simulator, a for Android emulator)
npm run web          # browser preview; append ?flavor=android to preview the Android look
npm run verify       # typecheck + lint + unit tests
npm run test:db      # database migrations + RLS tests (requires PostgreSQL 15+ binaries)
```

Native features (SF Symbols, native tabs, haptics) need a development build: `npx expo run:ios`, `npx expo run:android`, or EAS Build. They are not available in Expo Go.

In the app, open **More → Workspace profile (demo)** to switch between people in a real reporting hierarchy: Staff (Jordan) → Supervisor (Maya) → Manager (Elena) → Executive (Rafael) → **Owner (Sofia, full organization access)**, plus HR (Hana), Payroll (Paulo), Operations (Ivy) and IT admin (Alex), each with different access. Navigation, home widgets, what you can see and what you can approve all change, because the (mock) server enforces permissions. **More → Customize** sets theme, accent color, density, platform look (iOS/Android), sidebar style and the Home layout. Widen the browser past 600 px to get the desktop sidebar layout.

## Live mode (Supabase)

Without configuration the app runs the built-in demo organization. To use a real workspace:

1. **Database:** apply every file in `supabase/migrations/` to your Supabase project, in name order. Use `supabase db push` with the Supabase CLI, or paste each file into the SQL editor. Do not apply `supabase/tests/local_auth_shim.sql`; it is only for local test runs.
2. **Auth:** in Supabase → Authentication → URL Configuration, set the Site URL to where the web app runs (for example your Vercel domain), so confirmation and password-reset links come back to the app.
3. **App:** copy `apps/mobile/.env.example` to `apps/mobile/.env.local` and set `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_KEY` (the project's publishable key). For the web deployment, set the same two variables in Vercel → Project → Settings → Environment Variables.
4. **First run:** create an account, confirm the email, then create your organization (you become its owner). Add people under **People → Add employee** with the email of their NForce account.

Both settings are public by design. Never put a service-role or secret key in the app.

## Screenshots

| Phone (iOS look, light) | Phone (Android look, dark) |
| --- | --- |
| ![iOS screens](docs/screenshots/1-phone-ios-light.jpg) | ![Android screens](docs/screenshots/2-phone-android-dark.jpg) |

| Desktop | |
| --- | --- |
| ![Home](docs/screenshots/3-desktop-home.jpg) | ![Team table](docs/screenshots/4-desktop-team-table.jpg) |
| ![Approvals](docs/screenshots/5-desktop-approvals.jpg) | ![Timesheet with pay categories](docs/screenshots/6-desktop-timesheet-pay.jpg) |
| ![Customize, dark violet](docs/screenshots/7-desktop-customize-dark-violet.jpg) | ![Icon rail, compact, orange](docs/screenshots/8-desktop-rail-compact-orange.jpg) |
| ![Executive report](docs/screenshots/9-desktop-executive-reports.jpg) | ![Attendance](docs/screenshots/10-desktop-attendance.jpg) |
| ![Payroll register](docs/screenshots/11-desktop-payroll.jpg) | ![Permission matrix](docs/screenshots/12-desktop-permission-matrix.jpg) |
| ![Profile seen by HR](docs/screenshots/13-desktop-profile-hr.jpg) | ![CRM pipeline](docs/screenshots/14-desktop-crm.jpg) |
| ![Home, dark](docs/screenshots/15-desktop-home-dark.jpg) | ![Phone: home, executive report, attendance](docs/screenshots/16-phone-reports-attendance.jpg) |
| ![Timesheet table](docs/screenshots/17-desktop-timesheet-table.jpg) | ![Team roster (week)](docs/screenshots/18-desktop-team-roster.jpg) |
| ![Schedule month calendar](docs/screenshots/19-desktop-schedule-month.jpg) | ![Employee profile](docs/screenshots/20-desktop-employee-profile.jpg) |
| ![Custom filters on the team list](docs/screenshots/22-desktop-custom-filters.jpg) | ![Filter builder](docs/screenshots/23-desktop-filter-builder.jpg) |

Rendered from the production web bundle with Playwright, with mock data. Not yet captured on physical devices.

## Documentation

- [Enterprise Workforce Platform Architecture](docs/architecture/enterprise-workforce-platform.md): product modules, authorization, tenancy, workflows, delivery phases and the implementation map.
- [Mobile App Architecture](docs/architecture/mobile-app.md): layers, navigation, design system, reliability, accessibility, i18n and quality gates.
- [Architecture Decision Records](docs/architecture/decisions.md)
- [Award-Readiness Guide](docs/product/award-readiness.md): award programs, standards and a readiness scorecard.
- [Development Progress & Documentation Policy](docs/DEVELOPMENT_PROGRESS_POLICY.md)
- [Development Progress Log](docs/PROGRESS_LOG.md)
- [Pull Request Template](.github/pull_request_template.md)

## Required development practice

Every meaningful implementation change must update `docs/PROGRESS_LOG.md` in the same pull request and keep relevant feature/architecture documentation in sync. Record only tests and checks that were actually run. Clearly distinguish proposed, implemented, and verified behavior. Do not merge work with undocumented blockers or falsely claimed validation results.
