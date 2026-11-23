-- =============================================================================
-- NForce · Phase 1 foundation
-- Tenancy, memberships, organization structure, RBAC + ABAC permissions,
-- immutable attendance events with an idempotent clock RPC, and audit.
--
-- Security model (see docs/architecture/enterprise-workforce-platform.md §4, §6):
--   * Row-Level Security is enabled on every table (defense in depth).
--   * Clients never write attendance rows directly; they call
--     public.record_attendance_event(), which authorizes, validates the
--     transition, stamps the server time and is idempotent.
--   * Related records must belong to the same organization: enforced with
--     composite (organization_id, id) foreign keys, not just application code.
--   * Permission catalog and role templates mirror @nforce/core and are
--     checked for drift by packages/core/test/sql-parity.test.ts.
-- =============================================================================

create schema if not exists app;
revoke all on schema app from public;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type public.membership_status as enum ('invited', 'active', 'suspended', 'ended');
-- Declaration order matters: enum comparison gives self < team < department < organization.
create type public.access_scope as enum ('self', 'team', 'department', 'organization');
create type public.attendance_event_type as enum ('clock_in', 'break_start', 'break_end', 'clock_out');
create type public.attendance_source as enum ('mobile', 'web', 'kiosk', 'correction');

-- ---------------------------------------------------------------------------
-- Tenancy & organization structure
-- ---------------------------------------------------------------------------
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 200),
  time_zone text not null default 'UTC',
  created_at timestamptz not null default now()
);

create function app.validate_time_zone() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.time_zone) then
    raise exception 'invalid time zone: %', new.time_zone using errcode = '22023';
  end if;
  return new;
end $$;

create trigger organizations_time_zone before insert or update of time_zone on public.organizations
  for each row execute function app.validate_time_zone();

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (length(btrim(display_name)) between 1 and 120),
  created_at timestamptz not null default now()
);

create table public.departments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  unique (organization_id, id)
);

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  department_id uuid,
  name text not null check (length(btrim(name)) between 1 and 120),
  unique (organization_id, id),
  foreign key (organization_id, department_id) references public.departments (organization_id, id)
);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  status public.membership_status not null default 'invited',
  department_id uuid,
  created_at timestamptz not null default now(),
  unique (organization_id, user_id),
  unique (organization_id, id),
  foreign key (organization_id, department_id) references public.departments (organization_id, id)
);
create index memberships_user_idx on public.memberships (user_id) where status = 'active';

create table public.team_members (
  organization_id uuid not null,
  team_id uuid not null,
  membership_id uuid not null,
  primary key (team_id, membership_id),
  foreign key (organization_id, team_id) references public.teams (organization_id, id) on delete cascade,
  foreign key (organization_id, membership_id) references public.memberships (organization_id, id) on delete cascade
);
create index team_members_membership_idx on public.team_members (membership_id);

-- ---------------------------------------------------------------------------
-- Access control (RBAC + ABAC)
-- ---------------------------------------------------------------------------
create table public.permissions (
  key text primary key check (key ~ '^[a-z]+(\.[a-z_]+)+$')
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  -- NULL organization_id = platform role template, readable by every tenant.
  organization_id uuid references public.organizations (id) on delete cascade,
  key text not null check (key ~ '^[a-z_]+$'),
  name text not null,
  unique nulls not distinct (organization_id, key)
);

create table public.role_grants (
  role_id uuid not null references public.roles (id) on delete cascade,
  permission text not null references public.permissions (key),
  scope public.access_scope not null,
  primary key (role_id, permission)
);

create table public.membership_roles (
  membership_id uuid not null references public.memberships (id) on delete cascade,
  role_id uuid not null references public.roles (id) on delete cascade,
  primary key (membership_id, role_id)
);

-- A membership may only hold platform templates or roles of its own organization.
create function app.check_membership_role() returns trigger
language plpgsql set search_path = '' as $$
declare
  role_org uuid;
  member_org uuid;
begin
  select organization_id into role_org from public.roles where id = new.role_id;
  select organization_id into member_org from public.memberships where id = new.membership_id;
  if role_org is not null and role_org <> member_org then
    raise exception 'role belongs to another organization' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger membership_roles_same_tenant before insert or update on public.membership_roles
  for each row execute function app.check_membership_role();

create table public.delegations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  membership_id uuid not null,
  permission text not null references public.permissions (key),
  scope public.access_scope not null,
  starts_at timestamptz not null,
  expires_at timestamptz not null,
  reason text not null check (length(btrim(reason)) > 0),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  check (expires_at > starts_at),
  foreign key (organization_id, membership_id) references public.memberships (organization_id, id) on delete cascade
);
create index delegations_active_idx on public.delegations (membership_id, expires_at);

-- ---------------------------------------------------------------------------
-- Attendance (append-only source of truth)
-- ---------------------------------------------------------------------------
create table public.attendance_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  user_id uuid not null,
  type public.attendance_event_type not null,
  occurred_at timestamptz not null default now(),
  source public.attendance_source not null,
  idempotency_key text not null check (length(idempotency_key) between 8 and 128),
  note text check (note is null or length(note) <= 500),
  created_at timestamptz not null default now(),
  unique (organization_id, user_id, idempotency_key),
  foreign key (organization_id, user_id) references public.memberships (organization_id, user_id)
);
create index attendance_events_timeline_idx on public.attendance_events (organization_id, user_id, occurred_at desc);

create function app.forbid_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '% rows are immutable; append a correction instead', tg_table_name using errcode = '42501';
end $$;

create trigger attendance_events_immutable before update or delete on public.attendance_events
  for each row execute function app.forbid_mutation();

-- ---------------------------------------------------------------------------
-- Audit
-- ---------------------------------------------------------------------------
create table public.audit_events (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  actor_id uuid,
  action text not null,
  entity text not null,
  entity_id text,
  data jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);
create index audit_events_org_time_idx on public.audit_events (organization_id, occurred_at desc);

create trigger audit_events_immutable before update or delete on public.audit_events
  for each row execute function app.forbid_mutation();

-- ---------------------------------------------------------------------------
-- Authorization helpers (SECURITY DEFINER, fixed search_path, read-only)
-- ---------------------------------------------------------------------------

-- The caller's active membership in an organization (zero or one row).
create function app.active_membership(p_org uuid) returns setof public.memberships
language sql stable security definer set search_path = '' rows 1 as $$
  select m.* from public.memberships m
  where m.organization_id = p_org and m.user_id = auth.uid() and m.status = 'active'
$$;

create function app.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app.active_membership(p_org))
$$;

-- Narrowest scope covering the relationship between the caller and p_subject.
create function app.relation_scope(p_org uuid, p_subject uuid) returns public.access_scope
language sql stable security definer set search_path = '' as $$
  with me as (select * from app.active_membership(p_org)),
       them as (select m.* from public.memberships m where m.organization_id = p_org and m.user_id = p_subject)
  select case
    when p_subject is not null and p_subject = auth.uid() then 'self'::public.access_scope
    when exists (
      select 1 from public.team_members a
      join public.team_members b on b.team_id = a.team_id
      where a.membership_id = (select id from me) and b.membership_id = (select id from them)
    ) then 'team'::public.access_scope
    when (select department_id from me) is not null
      and (select department_id from me) = (select department_id from them) then 'department'::public.access_scope
    else 'organization'::public.access_scope
  end
$$;

-- Does the caller hold p_permission with a scope wide enough to reach p_subject?
-- p_subject NULL means an organization-wide resource.
create function app.has_permission(p_org uuid, p_permission text, p_subject uuid default null)
returns boolean
language sql stable security definer set search_path = '' as $$
  with me as (select * from app.active_membership(p_org)),
       grants as (
         select g.scope from public.membership_roles mr
         join public.role_grants g on g.role_id = mr.role_id
         where mr.membership_id = (select id from me) and g.permission = p_permission
         union all
         select d.scope from public.delegations d
         where d.membership_id = (select id from me) and d.permission = p_permission
           and now() >= d.starts_at and now() < d.expires_at
       )
  select exists (select 1 from me)
     and exists (select 1 from grants where scope >= app.relation_scope(p_org, p_subject))
$$;

revoke all on all functions in schema app from public;
grant usage on schema app to authenticated;
grant execute on function app.is_member(uuid), app.has_permission(uuid, text, uuid), app.relation_scope(uuid, uuid),
  app.active_membership(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Clock RPC: authorized, validated, server-timestamped and idempotent
-- ---------------------------------------------------------------------------
create function public.record_attendance_event(
  p_organization_id uuid,
  p_type public.attendance_event_type,
  p_idempotency_key text,
  p_source public.attendance_source default 'mobile',
  p_note text default null
) returns public.attendance_events
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_row public.attendance_events;
  v_last public.attendance_event_type;
  v_status text;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if not app.has_permission(p_organization_id, 'attendance.clock', v_user) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_source = 'correction' then
    raise exception 'corrections use the correction workflow' using errcode = '42501';
  end if;

  -- Retried delivery: return the original event unchanged.
  select * into v_row from public.attendance_events
  where organization_id = p_organization_id and user_id = v_user and idempotency_key = p_idempotency_key;
  if found then
    return v_row;
  end if;

  -- Serialize concurrent punches for the same person.
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || v_user::text, 0));

  select type into v_last from public.attendance_events
  where organization_id = p_organization_id and user_id = v_user
  order by occurred_at desc, created_at desc limit 1;

  v_status := case v_last
    when 'clock_in' then 'working' when 'break_end' then 'working'
    when 'break_start' then 'on_break' else 'off' end;

  if not (
    (v_status = 'off' and p_type = 'clock_in') or
    (v_status = 'working' and p_type in ('break_start', 'clock_out')) or
    (v_status = 'on_break' and p_type in ('break_end', 'clock_out'))
  ) then
    raise exception 'invalid_transition: cannot % while %', p_type, v_status using errcode = 'P0001';
  end if;

  insert into public.attendance_events (organization_id, user_id, type, occurred_at, source, idempotency_key, note)
  values (p_organization_id, v_user, p_type, now(), p_source, p_idempotency_key, nullif(btrim(p_note), ''))
  on conflict (organization_id, user_id, idempotency_key) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from public.attendance_events
    where organization_id = p_organization_id and user_id = v_user and idempotency_key = p_idempotency_key;
  end if;
  return v_row;
end $$;

revoke all on function public.record_attendance_event(uuid, public.attendance_event_type, text, public.attendance_source, text) from public;
grant execute on function public.record_attendance_event(uuid, public.attendance_event_type, text, public.attendance_source, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Row-Level Security
-- ---------------------------------------------------------------------------
alter table public.organizations enable row level security;
alter table public.profiles enable row level security;
alter table public.departments enable row level security;
alter table public.teams enable row level security;
alter table public.memberships enable row level security;
alter table public.team_members enable row level security;
alter table public.permissions enable row level security;
alter table public.roles enable row level security;
alter table public.role_grants enable row level security;
alter table public.membership_roles enable row level security;
alter table public.delegations enable row level security;
alter table public.attendance_events enable row level security;
alter table public.audit_events enable row level security;

create policy organizations_read on public.organizations for select to authenticated
  using (app.is_member(id));

create policy profiles_read on public.profiles for select to authenticated
  using (
    id = auth.uid() or exists (
      select 1 from public.memberships m
      where m.user_id = profiles.id and app.has_permission(m.organization_id, 'people.directory', m.user_id)
    )
  );
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy departments_read on public.departments for select to authenticated using (app.is_member(organization_id));
create policy teams_read on public.teams for select to authenticated using (app.is_member(organization_id));
create policy team_members_read on public.team_members for select to authenticated using (app.is_member(organization_id));

create policy memberships_read on public.memberships for select to authenticated
  using (user_id = auth.uid() or app.has_permission(organization_id, 'people.directory', user_id));

create policy permissions_read on public.permissions for select to authenticated using (true);
create policy roles_read on public.roles for select to authenticated
  using (organization_id is null or app.is_member(organization_id));
create policy role_grants_read on public.role_grants for select to authenticated
  using (exists (select 1 from public.roles r where r.id = role_id and (r.organization_id is null or app.is_member(r.organization_id))));
create policy membership_roles_read on public.membership_roles for select to authenticated
  using (exists (
    select 1 from public.memberships m where m.id = membership_id
      and (m.user_id = auth.uid() or app.has_permission(m.organization_id, 'admin.roles'))
  ));

create policy delegations_read on public.delegations for select to authenticated
  using (
    exists (select 1 from public.memberships m where m.id = membership_id and m.user_id = auth.uid())
    or app.has_permission(organization_id, 'admin.roles')
  );

-- Reads are scope-aware; there are deliberately no INSERT/UPDATE/DELETE policies:
-- the only write path is public.record_attendance_event().
create policy attendance_events_read on public.attendance_events for select to authenticated
  using (app.has_permission(organization_id, 'attendance.view', user_id));

create policy audit_events_read on public.audit_events for select to authenticated
  using (app.has_permission(organization_id, 'admin.audit'));

-- Table privileges: read-only for signed-in users, nothing for anonymous.
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on all tables in schema public from authenticated;
grant select on all tables in schema public to authenticated;
grant update (display_name) on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Seed: permission catalog and platform role templates (mirrors @nforce/core)
-- ---------------------------------------------------------------------------
insert into public.permissions (key) values
  ('attendance.clock'),
  ('attendance.view'),
  ('attendance.correct'),
  ('schedule.view'),
  ('schedule.manage'),
  ('schedule.swap.request'),
  ('timesheet.view'),
  ('timesheet.submit'),
  ('timesheet.approve'),
  ('timesheet.lock'),
  ('timesheet.adjust'),
  ('timeoff.request'),
  ('timeoff.view'),
  ('timeoff.approve'),
  ('work.view'),
  ('work.create'),
  ('work.assign'),
  ('people.directory'),
  ('people.view'),
  ('people.view.sensitive'),
  ('people.manage'),
  ('payroll.view'),
  ('payroll.prepare'),
  ('payroll.export'),
  ('crm.view'),
  ('crm.manage'),
  ('reports.personal'),
  ('reports.team'),
  ('reports.organization'),
  ('admin.settings'),
  ('admin.roles'),
  ('admin.audit');

insert into public.roles (organization_id, key, name) values
  (null, 'staff', 'staff'),
  (null, 'supervisor', 'supervisor'),
  (null, 'manager', 'manager'),
  (null, 'operations', 'operations'),
  (null, 'hr', 'hr'),
  (null, 'payroll', 'payroll'),
  (null, 'executive', 'executive'),
  (null, 'org_admin', 'org_admin');

insert into public.role_grants (role_id, permission, scope)
select r.id, v.permission, v.scope::public.access_scope
from (values
  ('staff', 'attendance.clock', 'self'),
  ('staff', 'attendance.view', 'self'),
  ('staff', 'schedule.view', 'self'),
  ('staff', 'schedule.swap.request', 'self'),
  ('staff', 'timesheet.view', 'self'),
  ('staff', 'timesheet.submit', 'self'),
  ('staff', 'timeoff.request', 'self'),
  ('staff', 'timeoff.view', 'self'),
  ('staff', 'work.view', 'self'),
  ('staff', 'work.create', 'self'),
  ('staff', 'reports.personal', 'self'),
  ('staff', 'people.directory', 'organization'),
  ('supervisor', 'attendance.clock', 'self'),
  ('supervisor', 'attendance.view', 'team'),
  ('supervisor', 'schedule.view', 'team'),
  ('supervisor', 'schedule.swap.request', 'self'),
  ('supervisor', 'timesheet.view', 'team'),
  ('supervisor', 'timesheet.submit', 'self'),
  ('supervisor', 'timeoff.request', 'self'),
  ('supervisor', 'timeoff.view', 'team'),
  ('supervisor', 'work.view', 'team'),
  ('supervisor', 'work.create', 'self'),
  ('supervisor', 'reports.personal', 'self'),
  ('supervisor', 'people.directory', 'organization'),
  ('supervisor', 'attendance.correct', 'team'),
  ('supervisor', 'timesheet.approve', 'team'),
  ('supervisor', 'timeoff.approve', 'team'),
  ('supervisor', 'work.assign', 'team'),
  ('supervisor', 'people.view', 'team'),
  ('supervisor', 'reports.team', 'team'),
  ('manager', 'attendance.clock', 'self'),
  ('manager', 'attendance.view', 'department'),
  ('manager', 'schedule.view', 'department'),
  ('manager', 'schedule.swap.request', 'self'),
  ('manager', 'timesheet.view', 'department'),
  ('manager', 'timesheet.submit', 'self'),
  ('manager', 'timeoff.request', 'self'),
  ('manager', 'timeoff.view', 'department'),
  ('manager', 'work.view', 'department'),
  ('manager', 'work.create', 'self'),
  ('manager', 'reports.personal', 'self'),
  ('manager', 'people.directory', 'organization'),
  ('manager', 'attendance.correct', 'department'),
  ('manager', 'schedule.manage', 'department'),
  ('manager', 'timesheet.approve', 'department'),
  ('manager', 'timeoff.approve', 'department'),
  ('manager', 'work.assign', 'department'),
  ('manager', 'people.view', 'department'),
  ('manager', 'reports.team', 'department'),
  ('operations', 'attendance.clock', 'self'),
  ('operations', 'attendance.view', 'organization'),
  ('operations', 'schedule.view', 'organization'),
  ('operations', 'schedule.swap.request', 'self'),
  ('operations', 'timesheet.view', 'self'),
  ('operations', 'timesheet.submit', 'self'),
  ('operations', 'timeoff.request', 'self'),
  ('operations', 'timeoff.view', 'self'),
  ('operations', 'work.view', 'organization'),
  ('operations', 'work.create', 'self'),
  ('operations', 'reports.personal', 'self'),
  ('operations', 'people.directory', 'organization'),
  ('operations', 'schedule.manage', 'organization'),
  ('operations', 'work.assign', 'organization'),
  ('operations', 'reports.team', 'organization'),
  ('hr', 'attendance.clock', 'self'),
  ('hr', 'attendance.view', 'self'),
  ('hr', 'schedule.view', 'self'),
  ('hr', 'schedule.swap.request', 'self'),
  ('hr', 'timesheet.view', 'self'),
  ('hr', 'timesheet.submit', 'self'),
  ('hr', 'timeoff.request', 'self'),
  ('hr', 'timeoff.view', 'organization'),
  ('hr', 'work.view', 'self'),
  ('hr', 'work.create', 'self'),
  ('hr', 'reports.personal', 'self'),
  ('hr', 'people.directory', 'organization'),
  ('hr', 'people.view', 'organization'),
  ('hr', 'people.view.sensitive', 'organization'),
  ('hr', 'people.manage', 'organization'),
  ('hr', 'timeoff.approve', 'organization'),
  ('payroll', 'attendance.clock', 'self'),
  ('payroll', 'attendance.view', 'self'),
  ('payroll', 'schedule.view', 'self'),
  ('payroll', 'schedule.swap.request', 'self'),
  ('payroll', 'timesheet.view', 'organization'),
  ('payroll', 'timesheet.submit', 'self'),
  ('payroll', 'timeoff.request', 'self'),
  ('payroll', 'timeoff.view', 'self'),
  ('payroll', 'work.view', 'self'),
  ('payroll', 'work.create', 'self'),
  ('payroll', 'reports.personal', 'self'),
  ('payroll', 'people.directory', 'organization'),
  ('payroll', 'timesheet.lock', 'organization'),
  ('payroll', 'timesheet.adjust', 'organization'),
  ('payroll', 'payroll.view', 'organization'),
  ('payroll', 'payroll.prepare', 'organization'),
  ('payroll', 'payroll.export', 'organization'),
  ('executive', 'attendance.clock', 'self'),
  ('executive', 'attendance.view', 'self'),
  ('executive', 'schedule.view', 'self'),
  ('executive', 'schedule.swap.request', 'self'),
  ('executive', 'timesheet.view', 'self'),
  ('executive', 'timesheet.submit', 'self'),
  ('executive', 'timeoff.request', 'self'),
  ('executive', 'timeoff.view', 'self'),
  ('executive', 'work.view', 'self'),
  ('executive', 'work.create', 'self'),
  ('executive', 'reports.personal', 'self'),
  ('executive', 'people.directory', 'organization'),
  ('executive', 'reports.team', 'organization'),
  ('executive', 'reports.organization', 'organization'),
  ('executive', 'crm.view', 'organization'),
  ('org_admin', 'attendance.clock', 'self'),
  ('org_admin', 'attendance.view', 'self'),
  ('org_admin', 'schedule.view', 'self'),
  ('org_admin', 'schedule.swap.request', 'self'),
  ('org_admin', 'timesheet.view', 'self'),
  ('org_admin', 'timesheet.submit', 'self'),
  ('org_admin', 'timeoff.request', 'self'),
  ('org_admin', 'timeoff.view', 'self'),
  ('org_admin', 'work.view', 'self'),
  ('org_admin', 'work.create', 'self'),
  ('org_admin', 'reports.personal', 'self'),
  ('org_admin', 'people.directory', 'organization'),
  ('org_admin', 'admin.settings', 'organization'),
  ('org_admin', 'admin.roles', 'organization'),
  ('org_admin', 'admin.audit', 'organization'),
  ('org_admin', 'people.view', 'organization')
) as v (role_key, permission, scope)
join public.roles r on r.organization_id is null and r.key = v.role_key;
