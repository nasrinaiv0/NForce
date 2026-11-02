# NForce Enterprise Workforce Platform Architecture

**Status:** Proposed architecture  
**Owner:** Product and Engineering  
**Last updated:** 2026-11-02  
**Scope:** Product blueprint and implementation guidance; this document does not claim that the described features have been implemented.

## 1. Product vision

NForce is planned as a multi-tenant enterprise platform combining workforce management, HR workflows, attendance, scheduling, timesheets, leave, task management, CRM, payroll preparation/integrations, reporting, and administration. It should provide tailored experiences for staff, supervisors, managers, Operations, HR, Payroll, Finance, executives, organization administrators, and platform operators.

**Product principle:** one platform, role-appropriate workspaces, shared business records, and a single authorization model enforced by the server.

## 2. Product modules

- **Workspace:** personalized home, global search/command palette, notifications, help.
- **Work Center:** assigned work, today/upcoming/overdue tasks, delegated work, team queues, approvals, follow-ups, projects.
- **People & HR:** employee directory, employment records, organization chart, onboarding/offboarding, documents, policies, performance workflows.
- **Attendance:** clock in/out, breaks, attendance events/sessions, missed punches, exceptions, corrections.
- **Scheduling:** shift templates, assignments, availability, shift swaps, coverage and conflicts.
- **Timesheets:** review, submission, approval, correction, locking and history.
- **Time Off:** distinct day-off/roster requests and policy-based leave requests/balances.
- **Payroll:** period preparation, approved-hour reconciliation, authorized adjustments, exports and reconciliation. Actual payroll/statutory calculations require validated jurisdiction-specific rules.
- **CRM:** leads, accounts, contacts, opportunities, activities, follow-ups, customer cases and pipelines.
- **Operations:** staffing, coverage, work queues, exceptions, workload and service indicators.
- **Reports:** personal, team, departmental and executive views with permission-aware aggregation.
- **Administration:** tenant settings, roles, policies, integrations, API credentials, retention, audit, subscriptions and platform health.
- **Automation:** durable workflows, reminders, escalations, event handling and execution history.

## 3. Workspace and organization model

Do not create a separate application for every job title. Use a shared application shell and assemble navigation, widgets, data scope, and actions from a user's active organization membership and permissions.

Suggested workspace profiles include:
- Individual / personal workspace
- Employee / staff
- Senior specialist
- Team leader / supervisor
- Manager / senior manager
- Operations / workforce planning
- HR / recruitment
- Payroll / Finance
- IT / Security
- Department head / executive
- Organization owner / administrator
- Platform operations / super administrator

These are defaults, not a fixed hierarchy. Organizations can define custom roles. A user may have different roles in different organizations or teams. Job title and seniority must not automatically grant access to sensitive data.

### Universal navigation

Desktop shell: organization/workspace selector, global search, quick-create, notifications, help, profile, and a permission-filtered sidebar.

Core navigation candidates: Home, Work, Attendance, Schedule, Timesheets, Time Off, People, CRM, Reports, Settings. The exact set is permission- and organization-aware.

Mobile shell: Home, Work, Clock/Attendance, Schedule, Profile/More. Important clock actions must be reachable quickly and remain accessible.

## 4. Authorization model

Use role-based access control (RBAC) combined with attribute-based access control (ABAC).

Authorization decisions consider:
- authenticated identity and verified organization membership;
- assigned role and explicit permissions;
- organization, legal entity, site, department and team scope;
- resource ownership and reporting relationships;
- employment state and field sensitivity;
- workflow state (for example, a locked timesheet);
- temporary delegation, expiration and approval authority.

Enforce authorization in backend services for every read and write. Hiding UI elements is not a security control. Use PostgreSQL Row-Level Security (RLS) as defense in depth, not as a replacement for service-level policy checks.

Default principle of least privilege:
- Staff access their own records and permitted shared resources.
- Supervisors access assigned team data and only authorized correction/approval actions.
- HR access is scoped to assigned HR responsibilities.
- Payroll access is restricted to payroll-required fields and workflows.
- Executives see aggregates by default; sensitive person-level drill-down requires explicit permission.
- Organization administrators manage their tenant but do not automatically gain platform infrastructure access.
- Platform operators do not automatically gain unrestricted access to tenant business data.

Include separation of duties for sensitive payroll actions, temporary access expiration, access reviews, and audited break-glass procedures if supported.

## 5. High-level architecture

1. **Client:** responsive TypeScript web application with shared design system and role-aware workspaces.
2. **Entry layer:** HTTPS, secure sessions, input validation, rate limits, tenant context, authorization and audit context.
3. **Modular application:** identity/tenancy; organization/permissions; people/HR; attendance/time; scheduling; leave/approvals; tasks/work; CRM; payroll integrations; notifications; reporting; documents; billing/entitlements.
4. **Data layer:** PostgreSQL, private object storage, durable job queue, transactional outbox, protected audit records, cache and reporting projections as justified.
5. **Integrations:** payroll/accounting, calendar, email, SSO, messaging, attendance devices and versioned APIs/webhooks.

### Recommended starting stack

- React + TypeScript; Next.js where it fits the existing repository.
- Tailwind CSS and accessible reusable UI primitives.
- A consistent motion library and shared design tokens.
- React Hook Form + Zod for form validation.
- TanStack Query for server-state caching and invalidation.
- PostgreSQL; Supabase may provide managed database, authentication and storage capabilities.
- Explicit backend application services for sensitive business rules.
- Durable background queue/workers and transactional outbox for consequential events.
- Vercel for the web app if compatible with runtime needs; use suitable worker/backend hosting for durable background processing.
- Structured logs, metrics, traces, error monitoring, backups and tested restoration.

**Architecture choice:** begin as a modular monolith with strict module boundaries and stable interfaces. Extract a service only when scale, isolation, or operational needs justify the added complexity. Do not introduce microservices solely for appearance.

## 6. Tenant isolation and data boundaries

Every tenant-owned record should include an organization scope, typically `organization_id`. Personal workspace records require an explicit owner/scope model rather than unrestricted tenant access.

Controls:
1. Resolve tenant membership from authenticated, validated server-side context; never trust a client-supplied organization ID as proof of access.
2. Enforce organization scope in application services and database policies.
3. Validate that related records belong to the same authorized organization.
4. Restrict privileged database credentials to trusted server-side code.
5. Apply tenant checks to file access, exports, background jobs, search and integrations.
6. Test cross-tenant reads, inserts, updates, deletes, bulk operations and indirect relationships.
7. Keep branding, settings, policies, data retention and integration secrets tenant-scoped.
8. Audit security-sensitive administrative actions.

## 7. Core domain entities

Logical entity groups (not a demand to create every table in the first release):

- Identity: profiles, sessions, preferences.
- Tenancy: organizations, memberships, organization settings, legal entities, locations, departments, teams, reporting relationships.
- Access: roles, permissions, role_permissions, membership_roles, delegations, access reviews.
- HR: employees, employment_records, employee_status_history, employee_documents.
- CRM: crm_accounts, crm_contacts, crm_deals/opportunities, crm_activities, customer_cases.
- Attendance: attendance_events, attendance_sessions, break_records, attendance_exceptions.
- Scheduling: shifts, shift_assignments, shift_templates, availability_records.
- Timesheets: timesheets, timesheet_entries, timesheet_approvals.
- Leave: leave_types, leave_balances, leave_requests, leave_transactions, day_off_requests.
- Work: tasks, task_assignments, task_comments, task_dependencies, projects.
- Approvals: workflow_definitions, approval_instances, approval_steps, approval_decisions.
- Payroll: payroll_periods, payroll_runs, payroll_adjustments, payroll_exports.
- Communication: notifications, announcements, notification_preferences.
- Documents: documents, document_versions, document_access_policies.
- Automation: workflow_runs, scheduled_jobs, outbox_events.
- Security: audit_events, security_events.
- SaaS administration: subscriptions, organization_entitlements, usage_records.

Separate login identity from employment relationship. Preserve employment and organizational history where required. Important records need explicit lifecycle states and controlled transitions.

## 8. Attendance, timesheets and payroll invariants

Keep distinct:
1. raw attendance events;
2. calculated work sessions;
3. reviewable timesheets and entries;
4. approved/locked payroll inputs;
5. payroll calculations, exports and payment outcomes from an integrated payroll provider.

Use server-authoritative timestamps, organization/site time zones, overnight-shift handling, configurable breaks, missed-punch exceptions, correction reasons, approvals and audit history. Account for daylight-saving changes in supported jurisdictions. Offline attendance, device/location checks and biometric methods require explicit product/privacy decisions and appropriate safeguards.

Day-off requests (roster preference) are distinct from leave requests (absence under a leave policy). A day-off request must not automatically deduct leave balance.

Suggested timesheet states: Draft → Submitted → Approved → Locked, with controlled return/rejection and correction paths. Locked records are not silently edited; post-lock changes use a traceable adjustment workflow.

Payroll rules must be versioned and reproducible. Configure by jurisdiction, legal entity, employment classification and applicable policy. Validate Philippine and any other applicable labor/statutory requirements with qualified professionals before production use.

## 9. Work Center and shared workflows

Work Center sections may include My Work, Today, Upcoming, Overdue, Assigned by Me, Team Queue, Approvals, Follow-ups, Projects and Completed.

A task may link to an employee, customer, shift, case or project. It should have an assignee, creator, team, status, priority, due date, reminders, comments, subtasks/dependencies, attachments and activity history as applicable.

Workflow example: leave request submitted → validate policy and balance → check staffing conflicts → route to authorized approver → record decision → update authoritative leave transaction and relevant roster projection → notify employee → retain audit history.

Use one authoritative request and idempotent workflow actions. Notifications and tasks reference the original business record rather than duplicating it.

## 10. Automation and event reliability

Use a transactional outbox for database changes that must reliably publish events. Use durable queues/workers for reminders, exports, integration calls and scheduled processing.

Required properties: idempotency, bounded retries with backoff, dead-letter handling, timeouts, duplicate-event detection, tenant context, execution history, safe replay, versioned workflows and authorization checks for consequential actions.

A notification failure must not undo an already committed approval. A failed business transaction must not produce a false success response.

## 11. UI, accessibility and motion

Use one design system: semantic color tokens, typography, spacing, responsive grids, reusable buttons/forms/tables/dialogs, consistent empty/loading/error states and dark-mode tokens.

Motion should be purposeful, brief and consistent. Starting targets:
- button feedback: 100–140 ms;
- hover/focus: 120–180 ms;
- popover: 140–200 ms;
- modal: 180–240 ms;
- sidebar: 180–240 ms;
- subtle page transition: 160–220 ms where useful.

Respect reduced-motion preferences, keyboard navigation, visible focus, screen-reader semantics and contrast. Never delay important actions for animation. Prefer transform/opacity for transitions and measure actual performance on representative devices. Target smooth 60 FPS on supported devices without making it a substitute for real performance testing.

## 12. Notifications and analytics

Support in-app and email first; add push, SMS or messaging integrations where justified. Define delivery retries, deduplication, user preferences, quiet hours and tenant policy. Avoid exposing salary, medical or confidential HR data in notification previews.

Start reporting with PostgreSQL and carefully designed queries. Introduce reporting projections or a warehouse when workload warrants it, so analytics do not degrade attendance and payroll transactions. Provide permission-aware personal, team, departmental and executive views. Forecasts must disclose assumptions and must not silently make consequential employment decisions.

## 13. Security, privacy and operations

Baseline: secure sessions and recovery, MFA options, least-privilege access, tenant isolation tests, RLS, private storage and expiring download links, secrets management/rotation, rate limiting, input validation, protected audit trails, dependency/secret scanning, monitoring, backups, tested restoration and incident response.

Define data minimization and retention by data category and jurisdiction. Assess Philippine Data Privacy Act requirements and other applicable employment, payroll and privacy rules with qualified advisors. Treat this document as technical planning, not a compliance certification.

## 14. Delivery phases

1. **Foundation:** app shell, identity, tenancy, memberships, organization structure, permissions, audit, CI/CD and isolation tests.
2. **Workforce core:** employee profiles, attendance, shifts, breaks, timesheets, day-off/leave requests, balances and supervisor approvals.
3. **Work Center & Operations:** tasks, delegation, approval queues, coverage, notifications, escalations and team reports.
4. **HR & Payroll:** employee lifecycle, documents, reconciliation, period locking, controlled adjustments and payroll exports.
5. **CRM:** leads, accounts, contacts, opportunities, activities, customer cases and Work Center integration.
6. **Enterprise analytics/admin:** executive reporting, custom policies, advanced workflows, SSO/provisioning and API administration.
7. **Intelligence:** permission-aware AI search/commands, forecasting and anomaly detection after foundational data and access controls are proven.

## 15. Release acceptance gates

- Tenant-isolation tests pass for all critical read/write paths.
- Permission tests cover role, record scope, field sensitivity and workflow state.
- Attendance retries cannot create duplicate events/sessions.
- Leave approval and roster updates are consistent and auditable.
- Timesheet approval, locking and correction paths are tested.
- Payroll exports are idempotent and reconcilable.
- Queue retry/dead-letter/replay behavior is tested.
- Critical UI paths meet accessibility and reduced-motion requirements.
- Production monitoring, backup and restoration procedures are documented and exercised.
- Progress documentation is updated in the same PR as every meaningful implementation change.

## 16. Open decisions

Confirm before implementation: initial customer scope (internal, multi-tenant SaaS, or both); target countries and payroll jurisdictions; repository/runtime constraints; first-release roles and modules; attendance evidence/location policy; offline requirements; identity provider/SSO needs; retention requirements; and payroll provider integrations.
