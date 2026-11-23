/**
 * Branded identifiers prevent accidentally passing one kind of ID where another
 * is expected (for example an employee ID where an organization ID belongs),
 * which is a common source of cross-tenant bugs.
 */
declare const brand: unique symbol;
export type Brand<T, B extends string> = T & { readonly [brand]: B };

export type OrganizationId = Brand<string, 'OrganizationId'>;
export type UserId = Brand<string, 'UserId'>;
export type MembershipId = Brand<string, 'MembershipId'>;
export type TeamId = Brand<string, 'TeamId'>;
export type DepartmentId = Brand<string, 'DepartmentId'>;
export type SiteId = Brand<string, 'SiteId'>;

export const OrganizationId = (value: string) => value as OrganizationId;
export const UserId = (value: string) => value as UserId;
export const MembershipId = (value: string) => value as MembershipId;
export const TeamId = (value: string) => value as TeamId;
export const DepartmentId = (value: string) => value as DepartmentId;
export const SiteId = (value: string) => value as SiteId;
