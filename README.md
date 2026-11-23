# NForce

NForce is an enterprise workforce platform with role-aware workspaces: attendance, schedules, timesheets, time off, a Work Center and approvals, with HR, payroll integrations, CRM and administration on the roadmap.

> **Current status (2026-11-23):** Phase 1 foundation is implemented: a native iOS and Android app (Expo / React Native), a fully tested shared domain core, and a PostgreSQL/Supabase schema with row-level security. The app runs against an in-memory backend that enforces the real business rules. Authentication and the live Supabase client are not built yet. See the [progress log](docs/PROGRESS_LOG.md) for verified evidence and known gaps.

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

In the app, open **More → Workspace profile (demo)** to switch between Staff, Supervisor, HR, Executive and other roles. Navigation, home widgets and allowed actions change because the (mock) server enforces permissions. **More → Platform look** switches between the iOS and Android designs.

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
