import { DepartmentId, OrganizationId, TeamId, UserId, type RoleTemplate, type Subject } from '../src';

export const ORG = OrganizationId('org_acme');
export const OTHER_ORG = OrganizationId('org_globex');
export const TEAM_A = TeamId('team_a');
export const TEAM_B = TeamId('team_b');
export const DEPT = DepartmentId('dept_ops');

export const ALICE = UserId('u_alice'); // staff, team A
export const BOB = UserId('u_bob'); // supervisor, team A
export const CARA = UserId('u_cara'); // staff, team B (same department)

export function subject(userId: UserId, roles: RoleTemplate[], overrides: Partial<Subject> = {}): Subject {
  return {
    userId,
    organizationId: ORG,
    status: 'active',
    roles,
    teamIds: [TEAM_A],
    departmentId: DEPT,
    ...overrides,
  };
}
