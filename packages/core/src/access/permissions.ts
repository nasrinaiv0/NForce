/**
 * Permission catalog.
 *
 * Permissions are `module.action` strings. The catalog is a closed `as const`
 * list so that a typo anywhere in the codebase is a compile-time error.
 */
export const PERMISSIONS = [
  // Attendance
  'attendance.clock',
  'attendance.view',
  'attendance.correct',
  // Scheduling
  'schedule.view',
  'schedule.manage',
  'schedule.swap.request',
  // Timesheets
  'timesheet.view',
  'timesheet.submit',
  'timesheet.approve',
  'timesheet.lock',
  'timesheet.adjust',
  // Time off
  'timeoff.request',
  'timeoff.view',
  'timeoff.approve',
  // Work Center
  'work.view',
  'work.create',
  'work.assign',
  // People & HR
  'people.directory',
  'people.view',
  'people.view.sensitive',
  'people.manage',
  // Payroll
  'payroll.view',
  'payroll.prepare',
  'payroll.export',
  // CRM
  'crm.view',
  'crm.manage',
  // Reports
  'reports.personal',
  'reports.team',
  'reports.organization',
  // Administration
  'admin.settings',
  'admin.roles',
  'admin.audit',
] as const;

export type Permission = (typeof PERMISSIONS)[number];

const PERMISSION_SET: ReadonlySet<string> = new Set(PERMISSIONS);

export const isPermission = (value: string): value is Permission => PERMISSION_SET.has(value);

/**
 * Data scope a permission grant applies to. Ordered from narrowest to widest.
 * `self` < `team` < `department` < `organization`.
 */
export const SCOPES = ['self', 'team', 'department', 'organization'] as const;
export type Scope = (typeof SCOPES)[number];

export const scopeRank = (scope: Scope): number => SCOPES.indexOf(scope);

/** A permission together with the widest data scope it is granted for. */
export interface Grant {
  readonly permission: Permission;
  readonly scope: Scope;
}

/** Default role templates. Organizations can clone and customize these. */
export const ROLE_TEMPLATES = [
  'staff',
  'supervisor',
  'manager',
  'operations',
  'hr',
  'payroll',
  'executive',
  'org_admin',
] as const;
export type RoleTemplate = (typeof ROLE_TEMPLATES)[number];

const g = (scope: Scope, ...permissions: Permission[]): Grant[] =>
  permissions.map((permission) => ({ permission, scope }));

const STAFF: Grant[] = [
  ...g(
    'self',
    'attendance.clock',
    'attendance.view',
    'schedule.view',
    'schedule.swap.request',
    'timesheet.view',
    'timesheet.submit',
    'timeoff.request',
    'timeoff.view',
    'work.view',
    'work.create',
    'reports.personal',
  ),
  ...g('organization', 'people.directory'),
];

/**
 * Least-privilege defaults. Note that seniority never implies sensitive-data
 * access: `people.view.sensitive` and payroll permissions are only granted to
 * HR and Payroll templates, and executives receive aggregate reports.
 */
export const ROLE_GRANTS: Readonly<Record<RoleTemplate, readonly Grant[]>> = {
  staff: STAFF,
  supervisor: [
    ...STAFF,
    ...g(
      'team',
      'attendance.view',
      'attendance.correct',
      'schedule.view',
      'timesheet.view',
      'timesheet.approve',
      'timeoff.view',
      'timeoff.approve',
      'work.view',
      'work.assign',
      'people.view',
      'reports.team',
    ),
  ],
  manager: [
    ...STAFF,
    ...g(
      'department',
      'attendance.view',
      'attendance.correct',
      'schedule.view',
      'schedule.manage',
      'timesheet.view',
      'timesheet.approve',
      'timeoff.view',
      'timeoff.approve',
      'work.view',
      'work.assign',
      'people.view',
      'reports.team',
    ),
  ],
  operations: [
    ...STAFF,
    ...g('organization', 'schedule.view', 'schedule.manage', 'attendance.view', 'work.view', 'work.assign', 'reports.team'),
  ],
  // HR sees all time off but does not approve it: approvals follow the
  // reporting line and are finalized by managers (see approvals/chain.ts).
  hr: [...STAFF, ...g('organization', 'people.view', 'people.view.sensitive', 'people.manage', 'timeoff.view', 'timesheet.view')],
  payroll: [
    ...STAFF,
    ...g('organization', 'timesheet.view', 'timesheet.lock', 'timesheet.adjust', 'payroll.view', 'payroll.prepare', 'payroll.export'),
  ],
  // Executives see aggregates and act as final approvers for managers' own
  // requests; person-level attendance detail is not granted by default.
  executive: [...STAFF, ...g('organization', 'reports.team', 'reports.organization', 'crm.view', 'timeoff.approve', 'timesheet.approve')],
  org_admin: [...STAFF, ...g('organization', 'admin.settings', 'admin.roles', 'admin.audit', 'people.view')],
};

/**
 * Merge grants from several roles, keeping the widest scope per permission.
 */
export function mergeGrants(...grantLists: ReadonlyArray<readonly Grant[]>): Map<Permission, Scope> {
  const merged = new Map<Permission, Scope>();
  for (const list of grantLists) {
    for (const { permission, scope } of list) {
      const current = merged.get(permission);
      if (current === undefined || scopeRank(scope) > scopeRank(current)) {
        merged.set(permission, scope);
      }
    }
  }
  return merged;
}
