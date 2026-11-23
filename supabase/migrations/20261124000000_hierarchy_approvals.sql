-- =============================================================================
-- NForce · Phase 2: reporting hierarchy, holiday calendar, hierarchical approvals
--
-- * memberships.reports_to builds the reporting line (same-tenant, cycle-free).
-- * Anyone in your reporting line (direct or indirect report) is in your
--   "team" scope for RLS, mirroring @nforce/core requiredScope().
-- * Requests (leave, day off, overtime, timesheet, correction) are routed up
--   the reporting line: supervisor review → manager FINAL approval. Managers
--   may decide at any stage (skipping pending review). Nobody decides their
--   own request. Mirrors @nforce/core approvals/chain.ts.
-- * Re-syncs platform role templates with @nforce/core (HR views time off but
--   no longer approves it; executives approve managers' own requests).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Reporting line
-- ---------------------------------------------------------------------------
alter table public.memberships add column reports_to uuid;
alter table public.memberships
  add constraint memberships_reports_to_same_org
    foreign key (organization_id, reports_to) references public.memberships (organization_id, id) on delete set null (reports_to),
  add constraint memberships_not_self_manager check (reports_to is null or reports_to <> id);
create index memberships_reports_to_idx on public.memberships (reports_to);

create function app.prevent_reporting_cycle() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.reports_to is not null and exists (
    with recursive up (id, depth) as (
      select new.reports_to, 1
      union all
      select m.reports_to, up.depth + 1 from public.memberships m
      join up on m.id = up.id
      where m.reports_to is not null and up.depth < 100
    )
    select 1 from up where id = new.id
  ) then
    raise exception 'reporting line would contain a cycle' using errcode = '23514';
  end if;
  return new;
end $$;

create trigger memberships_no_cycle before insert or update of reports_to on public.memberships
  for each row execute function app.prevent_reporting_cycle();

-- User ids of p_subject's managers, nearest first.
create function app.manager_chain(p_org uuid, p_subject uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
  with recursive up (membership_id, depth) as (
    select m.reports_to, 1 from public.memberships m
    where m.organization_id = p_org and m.user_id = p_subject and m.reports_to is not null
    union all
    select m.reports_to, up.depth + 1 from public.memberships m
    join up on m.id = up.membership_id
    where m.reports_to is not null and up.depth < 100
  )
  select coalesce(array_agg(m.user_id order by up.depth), '{}')
  from up join public.memberships m on m.id = up.membership_id
$$;

-- Scope now treats direct/indirect reports as "team", and looking UP the
-- reporting line (at your own managers) requires "organization" scope.
create or replace function app.relation_scope(p_org uuid, p_subject uuid) returns public.access_scope
language sql stable security definer set search_path = '' as $$
  with me as (select * from app.active_membership(p_org)),
       them as (select m.* from public.memberships m where m.organization_id = p_org and m.user_id = p_subject)
  select case
    when p_subject is not null and p_subject = auth.uid() then 'self'::public.access_scope
    when p_subject is not null and p_subject = any (app.manager_chain(p_org, auth.uid())) then 'organization'::public.access_scope
    when exists (
      select 1 from public.team_members a
      join public.team_members b on b.team_id = a.team_id
      where a.membership_id = (select id from me) and b.membership_id = (select id from them)
    ) then 'team'::public.access_scope
    when p_subject is not null and auth.uid() = any (app.manager_chain(p_org, p_subject)) then 'team'::public.access_scope
    when (select department_id from me) is not null
      and (select department_id from me) = (select department_id from them) then 'department'::public.access_scope
    else 'organization'::public.access_scope
  end
$$;

-- Does p_user hold any of the role keys (templates or custom) in p_org?
create function app.has_role(p_org uuid, p_user uuid, p_keys text[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.membership_roles mr on mr.membership_id = m.id
    join public.roles r on r.id = mr.role_id
    where m.organization_id = p_org and m.user_id = p_user and m.status = 'active' and r.key = any (p_keys)
  )
$$;

-- ---------------------------------------------------------------------------
-- Holiday calendar (drives regular/special holiday pay classification)
-- ---------------------------------------------------------------------------
create type public.holiday_kind as enum ('regular', 'special');

create table public.holidays (
  organization_id uuid not null references public.organizations (id) on delete cascade,
  date date not null,
  kind public.holiday_kind not null,
  name text not null check (length(btrim(name)) between 1 and 120),
  primary key (organization_id, date)
);
alter table public.holidays enable row level security;
create policy holidays_read on public.holidays for select to authenticated using (app.is_member(organization_id));

-- ---------------------------------------------------------------------------
-- Hierarchical approval requests
-- ---------------------------------------------------------------------------
create type public.request_kind as enum ('leave', 'day_off', 'overtime', 'timesheet', 'correction');
create type public.request_status as enum ('pending', 'approved', 'returned', 'cancelled');
create type public.approver_level as enum ('supervisor', 'manager');
create type public.step_status as enum ('waiting', 'pending', 'approved', 'returned', 'skipped');

create table public.approval_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  requester_id uuid not null,
  kind public.request_kind not null,
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload) = 'object'),
  status public.request_status not null default 'pending',
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  foreign key (organization_id, requester_id) references public.memberships (organization_id, user_id)
);
create index approval_requests_requester_idx on public.approval_requests (organization_id, requester_id, created_at desc);

create table public.approval_steps (
  request_id uuid not null references public.approval_requests (id) on delete cascade,
  position smallint not null check (position >= 1),
  organization_id uuid not null,
  level public.approver_level not null,
  approver_id uuid not null,
  status public.step_status not null,
  decided_by uuid,
  decided_at timestamptz,
  reason text,
  primary key (request_id, position),
  foreign key (organization_id, approver_id) references public.memberships (organization_id, user_id)
);
create index approval_steps_approver_idx on public.approval_steps (approver_id, status);

-- Permission needed to VIEW requests of a kind for someone in scope.
create function app.request_view_permission(p_kind public.request_kind) returns text
language sql immutable set search_path = '' as $$
  select case when p_kind in ('leave', 'day_off') then 'timeoff.view' else 'timesheet.view' end
$$;

create function public.submit_request(p_organization_id uuid, p_kind public.request_kind, p_payload jsonb default '{}'::jsonb)
returns public.approval_requests
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_permission text := case
    when p_kind in ('leave', 'day_off') then 'timeoff.request'
    when p_kind = 'correction' then 'attendance.clock'
    else 'timesheet.submit' end;
  v_supervisor uuid;
  v_manager uuid;
  v_ancestor uuid;
  v_request public.approval_requests;
  v_pos smallint := 1;
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if not app.has_permission(p_organization_id, v_permission, v_user) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  foreach v_ancestor in array app.manager_chain(p_organization_id, v_user) loop
    if app.has_role(p_organization_id, v_ancestor, array['manager', 'executive']) then
      v_manager := v_ancestor;
      exit;
    end if;
    if v_supervisor is null and app.has_role(p_organization_id, v_ancestor, array['supervisor']) then
      v_supervisor := v_ancestor;
    end if;
  end loop;
  if v_manager is null then
    raise exception 'no_approver: no manager-level approver in the reporting line' using errcode = 'P0001';
  end if;

  insert into public.approval_requests (organization_id, requester_id, kind, payload)
  values (p_organization_id, v_user, p_kind, coalesce(p_payload, '{}'::jsonb))
  returning * into v_request;

  if v_supervisor is not null then
    insert into public.approval_steps (request_id, position, organization_id, level, approver_id, status)
    values (v_request.id, v_pos, p_organization_id, 'supervisor', v_supervisor, 'pending');
    v_pos := v_pos + 1;
  end if;
  insert into public.approval_steps (request_id, position, organization_id, level, approver_id, status)
  values (v_request.id, v_pos, p_organization_id, 'manager', v_manager,
          case when v_supervisor is null then 'pending'::public.step_status else 'waiting'::public.step_status end);

  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (p_organization_id, v_user, 'request.submitted', 'approval_request', v_request.id::text, jsonb_build_object('kind', p_kind));
  return v_request;
end $$;

create function public.decide_request(p_request_id uuid, p_decision text, p_reason text default null)
returns public.approval_requests
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_request public.approval_requests;
  v_current public.approval_steps;
  v_final public.approval_steps;
  v_acting smallint;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_decision not in ('approve', 'return') then
    raise exception 'invalid decision' using errcode = '22023';
  end if;

  select * into v_request from public.approval_requests where id = p_request_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_request.status <> 'pending' then
    raise exception 'closed: request already decided' using errcode = 'P0001';
  end if;
  if v_request.requester_id = v_user then
    raise exception 'self_approval: you cannot decide your own request' using errcode = '42501';
  end if;
  if p_decision = 'return' and v_reason is null then
    raise exception 'reason_required' using errcode = 'P0001';
  end if;

  select * into v_current from public.approval_steps where request_id = p_request_id and status = 'pending' order by position limit 1;
  select * into v_final from public.approval_steps where request_id = p_request_id order by position desc limit 1;

  if v_current.approver_id = v_user then
    v_acting := v_current.position;
  elsif v_final.approver_id = v_user then
    v_acting := v_final.position; -- manager decides at any stage
  else
    raise exception 'not_approver' using errcode = '42501';
  end if;
  if not app.is_member(v_request.organization_id) then
    raise exception 'inactive_membership' using errcode = '42501';
  end if;

  update public.approval_steps set status = 'skipped'
  where request_id = p_request_id and position < v_acting and status in ('waiting', 'pending');

  update public.approval_steps
  set status = case when p_decision = 'approve' then 'approved'::public.step_status else 'returned'::public.step_status end,
      decided_by = v_user, decided_at = now(), reason = v_reason
  where request_id = p_request_id and position = v_acting;

  if p_decision = 'approve' and v_acting < v_final.position then
    update public.approval_steps set status = 'pending'
    where request_id = p_request_id and position = v_acting + 1 and status = 'waiting';
  else
    update public.approval_requests
    set status = case when p_decision = 'approve' then 'approved'::public.request_status else 'returned'::public.request_status end,
        decided_at = now()
    where id = p_request_id;
  end if;

  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_request.organization_id, v_user, 'request.' || p_decision, 'approval_request', p_request_id::text,
          jsonb_build_object('step', v_acting, 'reason', v_reason));

  select * into v_request from public.approval_requests where id = p_request_id;
  return v_request;
end $$;

alter table public.approval_requests enable row level security;
alter table public.approval_steps enable row level security;

-- One SECURITY DEFINER visibility check used by both policies (avoids RLS
-- recursion between the two tables): requester, any approver in the chain,
-- or someone holding the kind's view permission in scope.
create function app.can_view_request(p_request uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.approval_requests r
    where r.id = p_request and (
      r.requester_id = auth.uid()
      or exists (select 1 from public.approval_steps s where s.request_id = r.id and s.approver_id = auth.uid())
      or app.has_permission(r.organization_id, app.request_view_permission(r.kind), r.requester_id)
    )
  )
$$;

create policy approval_requests_read on public.approval_requests for select to authenticated
  using (app.can_view_request(id));
create policy approval_steps_read on public.approval_steps for select to authenticated
  using (app.can_view_request(request_id));

revoke all on public.holidays, public.approval_requests, public.approval_steps from anon;
revoke insert, update, delete, truncate on public.holidays, public.approval_requests, public.approval_steps from authenticated;
grant select on public.holidays, public.approval_requests, public.approval_steps to authenticated;

revoke all on function app.manager_chain(uuid, uuid), app.has_role(uuid, uuid, text[]), app.request_view_permission(public.request_kind), app.can_view_request(uuid) from public;
grant execute on function app.manager_chain(uuid, uuid), app.has_role(uuid, uuid, text[]), app.request_view_permission(public.request_kind), app.can_view_request(uuid) to authenticated;
revoke all on function public.submit_request(uuid, public.request_kind, jsonb), public.decide_request(uuid, text, text) from public;
grant execute on function public.submit_request(uuid, public.request_kind, jsonb), public.decide_request(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Re-sync platform role templates with @nforce/core (authoritative: last block)
-- ---------------------------------------------------------------------------
delete from public.role_grants where role_id in (select id from public.roles where organization_id is null);
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
  ('hr', 'timesheet.view', 'organization'),
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
  ('executive', 'timeoff.approve', 'organization'),
  ('executive', 'timesheet.approve', 'organization'),
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
