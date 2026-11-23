# Architecture Decision Records

Short, durable records of significant decisions. Status values: Proposed / Accepted / Superseded.

## ADR-001 — Expo + React Native in an npm-workspaces monorepo

- **Status:** Accepted (2026-11-23)
- **Context:** The product needs high-quality iOS and Android apps. The architecture recommends TypeScript and React, and the team needs to ship two platforms without two codebases.
- **Decision:** Build the mobile app with Expo SDK 58 / React Native 0.88 and Expo Router, in a monorepo (`apps/*`, `packages/*`) with npm workspaces. Use Continuous Native Generation (no hand-edited `ios/` or `android/`) and EAS for builds and updates.
- **Consequences:** One TypeScript codebase, truly native navigation (native tabs and stacks) and OTA updates. Native modules require development builds rather than Expo Go. Expo SDK upgrades are periodic work, which `expo install --fix` / `expo-doctor` help with.

## ADR-002 — Pure domain core shared by clients and mirrored by the database

- **Status:** Accepted (2026-11-23)
- **Context:** Authorization, attendance and timesheet rules are where costly bugs live (double clock-ins, self-approval, cross-tenant leaks).
- **Decision:** Put business rules in `@nforce/core`: framework-free, side-effect-free, `Result`-returning functions with ≥90% coverage thresholds. The server enforces the same rules. In SQL this is RLS plus `SECURITY DEFINER` RPCs, with a parity test guarding the permission seed.
- **Consequences:** The UI can show exactly what the server will allow (no "button that 403s"), and tests run in milliseconds. Rules exist in two languages (TS and SQL), and the parity test plus SQL tests keep them aligned.

## ADR-003 — Platform-adaptive design system with two native flavors

- **Status:** Accepted (2026-11-23)
- **Context:** A single "cross-platform" look feels foreign on both platforms. Fully separate UIs double the work.
- **Decision:** One semantic token vocabulary with two flavors, `ios` (HIG) and `android` (Material 3). Components read only tokens and `theme.flavor`. Navigation chrome is fully native (`NativeTabs`, native stack, sheets). The flavor can be switched at runtime for design review.
- **Consequences:** Each platform gets its own idioms (large titles vs top app bar, FAB vs header action, checkmark vs checkbox) from shared screens. New components must define both flavors.

## ADR-004 — Server-authoritative, idempotent, append-only attendance

- **Status:** Accepted (2026-11-23)
- **Context:** Mobile networks drop requests, users double-tap, and clocks on devices are wrong. Payroll depends on attendance being trustworthy.
- **Decision:** Clients send a client-generated idempotency key per user intent. Only the server sets `occurred_at`. Events are immutable, and sessions, totals and exceptions are derived by replay. Corrections are appended through a separate, audited workflow. The single write path is `record_attendance_event()`, which authorizes, locks per person, validates the transition and dedupes.
- **Consequences:** Retries and offline sync are safe by construction, and history is auditable. Displayed totals are derived and must be recomputed rather than edited.

## ADR-005 — In-memory backend behind a stable API contract (until Supabase integration)

- **Status:** Accepted (2026-11-23), to be superseded when the Supabase client lands
- **Context:** UX and rules need to be exercised before auth and hosting decisions (open questions in the architecture doc §16) are final.
- **Decision:** Screens depend on the `NForceApi` interface. `createMockApi` implements it using the real core rules and is also used in tests.
- **Consequences:** Product reviews and demos run without infrastructure. Do not present the mock as production behavior. Network latency, auth and persistence are simulated or absent.

## ADR-006 — Approvals follow the reporting line; managers give final approval

- **Status:** Accepted (2026-11-23)
- **Context:** Requests must be approved by the right people, with managers accountable for every request in their line, and without approval bottlenecks when a supervisor is unavailable.
- **Decision:** Route every request up `reports_to`: supervisor review, then manager final approval. Managers may decide at any stage (skipping review). Executives finalize managers' own requests. HR views but doesn't approve. Looking up the reporting line requires organization scope. The rules live in `@nforce/core` and are mirrored by SQL RPCs with RLS. Both are tested.
- **Consequences:** Accurate reporting lines become critical data (cycles are rejected; missing approvers fail loudly). Delegations cover absences.

## ADR-007 — Pay categories are classified as data-driven hours, not money

- **Status:** Accepted (2026-11-23)
- **Context:** Night differential, overtime, rest-day and holiday premiums drive payroll. Rules differ by jurisdiction and contract.
- **Decision:** Classify worked minutes per day into coded lines with multipliers from a versionable `PayPolicy` (PH Labor Code defaults, minimum OT block). Shifts are attributed to their start date. Payroll systems apply rates. OT is paid only when an approved OT request covers it.
- **Consequences:** Transparent, testable hours for employees and payroll. Money calculations, statutory contributions and alternative attribution rules remain payroll-provider responsibilities and must be validated by professionals.
