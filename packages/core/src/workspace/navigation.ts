import { hasPermission, type Subject } from '../access/policy';
import type { Permission } from '../access/permissions';

/**
 * Role-aware workspace composition. One app shell; modules and home widgets
 * are assembled from the member's effective permissions rather than from job
 * titles.
 */

export type ModuleId =
  | 'timesheets'
  | 'timeoff'
  | 'approvals'
  | 'people'
  | 'payroll'
  | 'crm'
  | 'reports'
  | 'admin';

export interface ModuleDefinition {
  readonly id: ModuleId;
  /** Any one of these permissions unlocks the module. */
  readonly anyOf: readonly Permission[];
}

export const MODULES: readonly ModuleDefinition[] = [
  { id: 'approvals', anyOf: ['timesheet.approve', 'timeoff.approve', 'attendance.correct'] },
  { id: 'timesheets', anyOf: ['timesheet.view'] },
  { id: 'timeoff', anyOf: ['timeoff.request', 'timeoff.view'] },
  { id: 'people', anyOf: ['people.directory', 'people.view'] },
  { id: 'payroll', anyOf: ['payroll.view'] },
  { id: 'crm', anyOf: ['crm.view', 'crm.manage'] },
  { id: 'reports', anyOf: ['reports.personal', 'reports.team', 'reports.organization'] },
  { id: 'admin', anyOf: ['admin.settings', 'admin.roles', 'admin.audit'] },
];

export function visibleModules(subject: Subject, now: Date = new Date()): ModuleId[] {
  return MODULES.filter((m) => m.anyOf.some((p) => hasPermission(subject, p, now))).map((m) => m.id);
}

export type HomeWidget = 'clock' | 'next_shift' | 'my_work' | 'balances' | 'team_pulse' | 'approvals' | 'org_metrics';

/** Home widgets in priority order for the member's workspace. */
export function homeWidgets(subject: Subject, now: Date = new Date()): HomeWidget[] {
  const has = (p: Permission) => hasPermission(subject, p, now);
  const widgets: HomeWidget[] = [];
  if (has('attendance.clock')) widgets.push('clock');
  if (has('timesheet.approve') || has('timeoff.approve')) widgets.push('approvals');
  if (has('schedule.view')) widgets.push('next_shift');
  if (has('reports.team')) widgets.push('team_pulse');
  if (has('reports.organization')) widgets.push('org_metrics');
  if (has('work.view')) widgets.push('my_work');
  if (has('timeoff.request')) widgets.push('balances');
  return widgets;
}
