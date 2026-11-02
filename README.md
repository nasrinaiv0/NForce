# NForce

NForce is being planned as an enterprise workforce platform with role-aware workspaces, workforce management, HR workflows, a unified Work Center, CRM, payroll integrations, and organization-level administration.

> **Current status:** The documents below establish a proposed architecture and development process. They do not imply that product features have been implemented or verified.

## Product and engineering documentation

- [Enterprise Workforce Platform Architecture](docs/architecture/enterprise-workforce-platform.md) — product modules, workspace model, authorization, tenant isolation, domain entities, workflows, security, and delivery phases.
- [Development Progress & Documentation Policy](docs/DEVELOPMENT_PROGRESS_POLICY.md) — required documentation and validation expectations for every meaningful development PR.
- [Development Progress Log](docs/PROGRESS_LOG.md) — dated project progress, actual validation evidence, known gaps, and next steps.
- [Pull Request Template](.github/pull_request_template.md) — required progress, documentation, testing, and risk checklist.

## Required development practice

Every meaningful implementation change must update `docs/PROGRESS_LOG.md` in the same pull request and keep relevant feature/architecture documentation in sync. Record only tests and checks that were actually run. Clearly distinguish proposed, implemented, and verified behavior. Do not merge work with undocumented blockers or falsely claimed validation results.
