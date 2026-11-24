# P1.5 arithmetic equivalence and visibility acceptance

Baseline: f6d1daa852db55c924ddb3c3d442a6741255e7b6 (CI 45323194011 all green; matching preview; six browser screenshots). PR26 only. No hosted migration, real employee data, new PR, paid resources, merge or production change.

## Equivalence scope
Forward migration 20261221000000 extracts two private immutable numeric expressions, with original PostgreSQL operator order and no rounding. Weekly and cutoff functions keep all original guards, evidence adapters, gross rounding, and journal/replay functions. Four existing transactional fictional fixtures execute before and after the migration in the same disposable cluster; deterministic snapshot fields, exact journal/reversal lines, effective revisions and annual settlement figures must be byte-identical. 678 expression/scale comparisons and null propagation, privilege checks. Existing concurrency and security tests run separately. No new calculator or ledger.

## Intentional behavior differences — not approved for normalization
- Weekly uses its reviewed salary calendar allocation; cutoff uses reviewed full-month basis; partial months and cross-cutoff shifts remain restricted.
- Weekly has verified prior-employer path; cutoff rejects prior certificates until integrated.
- Weekly counts related periods differently from cutoff's nonzero-gross count; cumulative trigger differs; do not silently change.
- Weekly deducts employee contributions; cutoff requires reviewed deductible amount and special MWE limits. No automatic harmonization.
- Weekly and cutoff source eligibility, daily wage evidence and paid-leave shape differ; exact premium decomposition and rounding must remain unchanged.
- Different idempotent retry/attestation rules are unchanged; real payroll/tax/benefit corrections and statutory claims remain gated.
Independent CPA to reproduce all rates/rounding and tax differences; counsel to verify eligibility and wage orders, security to verify actor/scope, locking, releases and RLS. Any behavioral change requires separate written acceptance and regression evidence. No independent review has been performed.

## Role separation
Existing RBAC/relationship scope: staff own records; supervisor reporting team; manager department and reporting line, never upward; operations authorized organization operational records; HR employment and sensitive people records, no management payroll; payroll/owner authorized organization monetary review, no HR-sensitive access for payroll by default; executive aggregate reports and scoped approvals, no automatic individual payroll; IT role administration not financial access. Basic directory may remain organization-visible per existing permission; not salary/attendance/HR visibility. No new privileges for department or hierarchy roles. Existing organization review requires payroll.prepare and a current accounting_review_access grant; direct navigation is gated by current session identity, workspace and module, not a client authorization substitute. Employees can enter Payroll for personal view without the management module.

New payroll_self_snapshot derives employee identity solely from auth.uid(), active membership, existing review gate, effective revision and explicit private per-revision release. No caller-provided employee ID. Response allowlist: org/user/period/revision/source, gross, employee SSS/PhilHealth/Pag-IBIG and combined deductions, withholding and net. No employer amounts, employer cost, raw source evidence or journals. Private release metadata has distinct preparer/reviewer and no public writer, no production seed; reviewed accrual only, not payslip or proof of payment. Actual issuance/release workflow, revocation/retention, departed employee access policy, broader live HR and all role/department screens require independent acceptance. Reversal invalidates previous release; replacement requires separate release. Strict client parser rejects unknown fields, mismatched identity/tenant/period and inconsistent totals; no local payroll persistence. Browser owner/employee demo evidence only. Independent security tests must also cover delegated custom permissions, hierarchy changes, stale sessions, caches and exports; no production approval.

## UI review
Claude review layout, padding, typography, buttons, mobile/tablet/desktop, accessibility, no management fields in employee mode, and role navigation. Existing 320/390/1440 owner checks retained; staff personal screenshot added. Native JS exports are not physical-device acceptance.
