# NForce Mobile App Architecture (iOS & Android)

**Status:** Implemented (Phase 1 foundation, workforce core preview) — runs against an in-memory backend  
**Last updated:** 2026-11-23  
**Code:** [`apps/mobile`](../../apps/mobile), [`packages/core`](../../packages/core), [`supabase`](../../supabase)

This document describes what is **implemented** in the repository today. Items marked *Planned* are not built yet.

## 1. Goals

1. Feel native on both platforms: iOS follows Apple's Human Interface Guidelines, Android follows Material Design 3. Same product, two native looks.
2. Make wrong states hard to reach: business rules live in one pure, fully tested package used by every client and mirrored by the database.
3. Be cheap to operate: idempotent writes, server-authoritative time, typed errors, no client trust. These remove whole classes of production incidents.
4. Be inclusive and international from day one: Dynamic Type/font scaling, screen-reader labels, reduced motion, dark mode, three languages and locale-correct dates and times.

## 2. Repository layout

```
apps/mobile/            Expo SDK 58 · React Native 0.88 · React 19 · Expo Router
  src/app/              File-based routes (every file is a screen)
    (tabs)/             Native tab bar: home, work, clock, schedule, more
    new-task.tsx        Form sheet (iOS detents / Android bottom sheet)
    request-time-off.tsx  Modal flow with range calendar + live policy check
  src/components/       Platform-adaptive design-system components
  src/design/           Tokens (iOS + Material 3 palettes, type ramps, shapes, motion), theme, haptics
  src/data/             API contract, in-memory backend, TanStack Query hooks
  src/i18n/             en / fil / es dictionaries, plural + Intl formatting
  src/state/            Tiny selector store + validated persisted preferences
  test/                 Vitest: i18n parity, mock API rule enforcement
packages/core/          @nforce/core — framework-free domain logic (100% line coverage)
supabase/migrations/    PostgreSQL schema, RLS, clock RPC, seeds
supabase/tests/         SQL security tests (tenant isolation, RLS, idempotency)
scripts/test-db.sh      Runs migrations + SQL tests on a throwaway Postgres
```

## 3. Layers

```
 Screens (src/app)  ──>  Hooks (src/data/queries.ts, TanStack Query)
        │                         │
        ▼                         ▼
 Design system            NForceApi interface (src/data/types.ts)
 (src/components)           ├─ createMockApi()  ← implemented, uses @nforce/core
                            └─ Supabase client  ← Planned, same interface
                                      │
                                      ▼
                     @nforce/core (authorization, attendance, timesheets,
                     leave, work, time) — also mirrored in SQL + RLS
```

- **Screens never call the backend directly.** They use hooks; hooks call the `NForceApi` interface. Swapping the in-memory backend for Supabase changes one file (`queries.ts`), not screens.
- **The mock backend is honest.** Every write in `createMockApi` runs through the same `@nforce/core` functions the server will enforce: `authorize`, `recordEvent`, `evaluateTimeOff`, `transitionTimesheet`. Switching the demo persona really changes what the "server" allows.

## 4. Domain core (`@nforce/core`)

| Module | What it guarantees |
| --- | --- |
| `access/permissions` | Closed permission catalog (typos are compile errors); least-privilege role templates; widest-scope merge. |
| `access/policy` | `authorize()` = tenant match → active membership → permission → scope (self/team/department/organization) → sensitive-field gate → locked-record gate → separation of duties (no self-approval). Time-boxed delegations. Fails closed. |
| `attendance` | Raw events are immutable; sessions/totals/exceptions are derived by replay. Idempotency keys dedupe retries. Overnight shifts are attributed to the clock-in date in the org's zone. Out-of-sequence punches, open breaks and missed clock-outs are flagged, not silently "fixed". |
| `timesheet` | `draft → submitted → approved → locked`, with return/reopen requiring reasons; locked sheets only accept appended, audited adjustments; optimistic-concurrency `version`. |
| `leave` | Leave (consumes balance) vs day-off (roster request, **never** consumes balance); notice, max length, half-day and overlap rules. |
| `work` | Task buckets (overdue/today/upcoming/someday/done) and stable ordering. |
| `time` | Explicit IANA zones only; DST-safe calendar arithmetic; wall-clock → instant conversion. |
| `workspace` | Modules and home widgets assembled from permissions, not job titles. |

Errors are values (`Result<T, DomainError>`), never thrown for expected business failures, so callers must handle them.

## 5. Navigation & platform UI

- **Tabs:** `expo-router/native-tabs` renders the real `UITabBar` on iOS (Liquid Glass and minimize-on-scroll on iOS 26+) and the Material 3 `NavigationBar` on Android, with SF Symbols / Material Symbols. The web preview uses a JS bottom bar styled to the active flavor.
- **Stacks:** native stack per tab. iOS gets collapsing large titles over a blurred translucent bar; Android gets an M3 top app bar and `fade_from_bottom` transitions; predictive back gesture is enabled.
- **Sheets & modals:** the new-task sheet uses iOS form-sheet detents with a grabber. Time-off uses a full modal.
- **Flavors:** `src/design/tokens.ts` defines one semantic vocabulary with two palettes, type ramps (HIG Dynamic Type sizes vs M3 type scale) and shape scales. Components only read tokens. Platform-specific behavior includes capsule buttons vs M3 filled/tonal/outlined buttons, iOS round checkmarks vs M3 checkboxes, an iOS segmented control vs M3 segmented buttons, and an Android-only FAB (iOS uses a header "+").
- **Press feedback:** native ripple on Android; native-driver spring scale + highlight on iOS; semantic haptics (`selection`, `success`, `warning`…), user-toggleable.
- **Design review:** *More → Platform look* switches flavors at runtime. On web, `?flavor=android` previews the Android look.

## 6. Data, state & reliability

| Concern | Implementation |
| --- | --- |
| Server state | TanStack Query with a typed key factory. Business errors (`ApiError`) are never retried; transient errors retry with exponential backoff (max 8 s). |
| Optimistic UX | Task completion and approval decisions update instantly and roll back on failure. |
| Double-submit / retries | Clock actions carry a client idempotency key generated once per user intent and reused on retry; the server (core + SQL RPC) returns the original event. |
| Time | Server stamps `occurred_at`; clients cannot set it. All display uses the org zone. |
| Local preferences | Validated with Zod on load; corrupt/old payloads fall back to defaults instead of crashing. |
| Crash containment | Route-level `ErrorBoundary`; per-screen error and empty states with retry. |
| Battery | Live timers tick only while a session is open and pause when the app is backgrounded. |
| Rendering | React Compiler enabled; selector-based store; memoized primitives; native-driver animations; route-level code splitting (web bundle). |

## 7. Accessibility & internationalization

- Font scaling up to 2× (dense numerals capped lower), every control has a role, label and state, live regions announce clock changes and policy feedback, timers expose a spoken duration instead of ticking seconds, minimum touch targets (44 pt iOS / 48 dp Android), reduced-motion honored from OS **or** app setting, full dark mode.
- English, Filipino and Spanish. Dictionaries are typed against English (missing key = compile error), and a test enforces identical placeholders across locales. Dates, times, numbers, plurals and relative times use `Intl` with the device region when it matches the chosen language.

## 8. Backend foundation (`supabase/`)

The migration `20261123000000_foundation.sql` implements tenancy, organization structure, RBAC + ABAC, immutable attendance and audit:

- Composite `(organization_id, id)` foreign keys make cross-tenant relationships impossible at the database level.
- RLS on every table; scope-aware read policies via `app.has_permission(org, permission, subject)`, which mirrors `authorize()` including delegations.
- `public.record_attendance_event()` is the only attendance write path. It authorizes, serializes per person with an advisory lock, validates the transition, stamps `now()`, and is idempotent.
- Attendance and audit rows are immutable (trigger blocks update/delete, even for superusers).
- The permission catalog and role templates are seeded from `@nforce/core`; `packages/core/test/sql-parity.test.ts` fails if they drift.

## 9. Quality gates

| Gate | Command | Where |
| --- | --- | --- |
| Typecheck (strict, `noUncheckedIndexedAccess`) | `npm run typecheck` | CI `verify` |
| Lint (Expo + React Compiler rules, 0 warnings) | `npm run lint` | CI `verify` |
| Core unit tests + coverage thresholds | `npm run test:coverage -w @nforce/core` | CI `verify` |
| App unit tests | `npm run test -w @nforce/mobile` | CI `verify` |
| Migrations + RLS tests on real Postgres | `npm run test:db` | CI `database` |
| Production bundle compiles | `npx expo export --platform web` | CI `web-bundle` |

## 10. Running it

```bash
npm install
npm run start          # Expo dev server; press i / a for simulators, or scan with a dev build
npm run web            # browser preview (add ?flavor=android to preview the Android look)
npm run verify         # typecheck + lint + unit tests
npm run test:db        # migrations + SQL security tests (needs PostgreSQL 15+ binaries)
```

Native modules (SF Symbols, native tabs, haptics) need a development build (`npx expo run:ios` / `run:android`, or EAS Build). They are not available in Expo Go.

## 11. Known gaps (not implemented)

- Real authentication and the Supabase-backed `NForceApi` (mock only today).
- Offline outbox for clock events (idempotency keys are ready for it).
- Push notifications, widgets/Live Activities, Wear OS / watchOS.
- Native-device verification: the UI was verified with typecheck, lint and rendered web previews of both flavors. It has **not** yet been run on physical iOS/Android devices or simulators in CI.
- Screens for People, Payroll, CRM, Reports and Admin (roadmap placeholders with permissions wired).
- Timesheet/leave/approval tables in SQL (Phase 2). The foundation migration covers tenancy, access and attendance.
