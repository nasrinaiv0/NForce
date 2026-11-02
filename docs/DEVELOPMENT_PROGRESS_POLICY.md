# NForce Development Progress & Documentation Policy

**Status:** Proposed project policy  
**Effective for:** All new work and future pull requests  
**Applies to:** Product, engineering, design, database, infrastructure, testing, security and documentation changes.

## Mandatory rule

Every meaningful development progress update must be documented in the same pull request as the code or configuration change. Do not treat a PR description, commit message, chat update, or verbal report as a substitute for durable repository documentation.

A PR is not ready for review until its documentation is updated, or the author explicitly records why no additional documentation is appropriate.

## Required documentation for each PR

1. **Progress log:** Add an entry to `docs/PROGRESS_LOG.md` describing the change, status, evidence, and next steps.
2. **Implementation documentation:** Update the relevant architecture, feature, API, schema, workflow, operations, or user documentation whenever behavior or design changes.
3. **Tests and validation:** Record exact checks run and their outcomes. Do not claim a test passed unless it was actually run and passed.
4. **Known limitations:** Document unresolved issues, blockers, risks, migrations, rollout concerns, and any manual verification still needed.
5. **Acceptance criteria:** Link the change to testable acceptance criteria or include them in the PR description.
6. **Operational changes:** For database, secrets, deployment, integrations, queues or permissions, document rollout, rollback/recovery, and monitoring implications where relevant.
7. **Screenshots or evidence:** For significant UI changes, include before/after screenshots or other review evidence when practical and safe.

## Progress log format

Each entry in `docs/PROGRESS_LOG.md` should include:

- Date (UTC or explicit timezone)
- PR and issue links, when available
- Phase/module
- Summary of change
- Files or systems affected
- Status: Planned / In Progress / Implemented / Verified / Blocked
- Tests/checks actually run and results
- Security, data migration, accessibility, and performance implications as applicable
- Known gaps/blockers
- Next steps and owner/role where known

Keep entries append-only where practical. Correct mistakes with a follow-up entry rather than silently rewriting historical progress.

## Pull request checklist

Copy this checklist into PR descriptions or ensure equivalent repository automation enforces it:

- [ ] Progress log updated in this PR.
- [ ] Relevant product/architecture/API/schema/operations docs updated.
- [ ] Acceptance criteria are testable and addressed.
- [ ] Tests/checks are listed with truthful results.
- [ ] Known gaps, risks and blockers are recorded.
- [ ] Database migrations and rollback/recovery steps are documented, if applicable.
- [ ] Tenant isolation and authorization implications are tested, if applicable.
- [ ] Accessibility, responsive behavior and reduced-motion behavior are checked for UI changes, if applicable.
- [ ] No secrets, credentials, or unnecessary personal data are included in docs, logs, screenshots or fixtures.

## Documentation quality rules

- Document observed behavior, not intended behavior, as if it already exists.
- Label proposals and planned features clearly as **Proposed**, **Planned**, or **Not implemented**.
- Never claim production deployment, successful tests, security compliance, or completed migrations without evidence.
- Prefer concise, task-focused documentation with links to the source of truth.
- Keep architecture decisions and their rationale durable in the repository.
- If a change is intentionally documentation-only, say so and describe the review performed.
- If no additional feature documentation is necessary, explain why in the progress entry.

## Review and merge gate

Reviewers should request changes when required progress documentation is absent, materially inaccurate, or inconsistent with the code. Configure branch protection/CI to enforce automated checks where possible. A checklist alone is a human process control; it does not technically block merges unless repository rules or a status check enforce it.

## Suggested automation

In a follow-up engineering change, add CI validation that:
- requires `docs/PROGRESS_LOG.md` to change for non-trivial implementation PRs;
- checks required PR template sections;
- validates links and Markdown;
- optionally flags source changes without relevant docs changes for reviewer attention.

Avoid brittle rules that require a progress-log edit for every trivial formatting-only commit. The policy applies to meaningful development progress, with exceptions explained in the PR.
