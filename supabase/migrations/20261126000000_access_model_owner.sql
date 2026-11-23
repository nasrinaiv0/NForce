-- =============================================================================
-- NForce · Access model v2: organization owner, distinct department roles,
-- request validation, owner approval override and employee management RPCs.
--
-- * New permissions: people.offboard, org.manage. New role template: owner
--   (every permission, organization-wide). Department templates re-synced:
--   HR (people + attendance/time-off oversight, no approvals, no payroll),
--   Payroll (timesheets, locking, exports; no employee edits), Operations
--   (schedules), IT admin (settings/roles/audit; no business data).
-- * Owners may decide any request at any stage; nobody decides their own.
-- * assign_role() refuses privilege escalation: the caller must already hold
--   every permission of the role at least as widely. No self-assignment.
-- * offboard_member() reassigns direct reports to the departing person's
--   manager and protects the last owner. Mirrors @nforce/core.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Permission catalog, role templates and grants (authoritative: last block)
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
  ('people.offboard'),
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
  ('admin.audit'),
  ('org.manage')
on conflict do nothing;

insert into public.roles (organization_id, key, name) values
  (null, 'staff', 'staff'),
  (null, 'supervisor', 'supervisor'),
  (null, 'manager', 'manager'),
  (null, 'operations', 'operations'),
  (null, 'hr', 'hr'),
  (null, 'payroll', 'payroll'),
  (null, 'executive', 'executive'),
  (null, 'org_admin', 'org_admin'),
  (null, 'owner', 'owner')
on conflict do nothing;

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
  ('hr', 'attendance.view', 'organization'),
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
  ('hr', 'people.offboard', 'organization'),
  ('hr', 'reports.team', 'organization'),
  ('payroll', 'attendance.clock', 'self'),
  ('payroll', 'attendance.view', 'organization'),
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
  ('payroll', 'people.view', 'organization'),
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
  ('owner', 'attendance.clock', 'organization'),
  ('owner', 'attendance.view', 'organization'),
  ('owner', 'attendance.correct', 'organization'),
  ('owner', 'schedule.view', 'organization'),
  ('owner', 'schedule.manage', 'organization'),
  ('owner', 'schedule.swap.request', 'organization'),
  ('owner', 'timesheet.view', 'organization'),
  ('owner', 'timesheet.submit', 'organization'),
  ('owner', 'timesheet.approve', 'organization'),
  ('owner', 'timesheet.lock', 'organization'),
  ('owner', 'timesheet.adjust', 'organization'),
  ('owner', 'timeoff.request', 'organization'),
  ('owner', 'timeoff.view', 'organization'),
  ('owner', 'timeoff.approve', 'organization'),
  ('owner', 'work.view', 'organization'),
  ('owner', 'work.create', 'organization'),
  ('owner', 'work.assign', 'organization'),
  ('owner', 'people.directory', 'organization'),
  ('owner', 'people.view', 'organization'),
  ('owner', 'people.view.sensitive', 'organization'),
  ('owner', 'people.manage', 'organization'),
  ('owner', 'people.offboard', 'organization'),
  ('owner', 'payroll.view', 'organization'),
  ('owner', 'payroll.prepare', 'organization'),
  ('owner', 'payroll.export', 'organization'),
  ('owner', 'crm.view', 'organization'),
  ('owner', 'crm.manage', 'organization'),
  ('owner', 'reports.personal', 'organization'),
  ('owner', 'reports.team', 'organization'),
  ('owner', 'reports.organization', 'organization'),
  ('owner', 'admin.settings', 'organization'),
  ('owner', 'admin.roles', 'organization'),
  ('owner', 'admin.audit', 'organization'),
  ('owner', 'org.manage', 'organization')
) as v (role_key, permission, scope)
join public.roles r on r.organization_id is null and r.key = v.role_key;

-- ---------------------------------------------------------------------------
-- Request validation + owner as top approval tier
-- ---------------------------------------------------------------------------
create or replace function app.validate_request_payload(p_org uuid, p_kind public.request_kind, p_payload jsonb) returns void
language plpgsql stable set search_path = '' as $$
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'invalid_payload: object expected' using errcode = '22023';
  end if;
  case p_kind
    when 'leave' then
      if not (p_payload ? 'leaveTypeId' and p_payload ? 'start' and p_payload ? 'end' and p_payload ? 'days') then
        raise exception 'invalid_payload: leaveTypeId, start, end and days are required' using errcode = '22023';
      end if;
      if (p_payload ->> 'days')::numeric <= 0 or (p_payload ->> 'end')::date < (p_payload ->> 'start')::date then
        raise exception 'invalid_payload: invalid leave range' using errcode = '22023';
      end if;
      if not exists (select 1 from public.leave_types t where t.organization_id = p_org and t.key = p_payload ->> 'leaveTypeId') then
        raise exception 'invalid_payload: unknown leave type' using errcode = '22023';
      end if;
    when 'day_off' then
      if not (p_payload ? 'start' and p_payload ? 'end') or (p_payload ->> 'end')::date < (p_payload ->> 'start')::date then
        raise exception 'invalid_payload: start and end are required' using errcode = '22023';
      end if;
    when 'overtime' then
      if not (p_payload ? 'date' and p_payload ? 'minutes') or (p_payload ->> 'minutes')::integer not between 15 and 720 then
        raise exception 'invalid_payload: date and 15–720 minutes are required' using errcode = '22023';
      end if;
      perform (p_payload ->> 'date')::date;
    when 'timesheet' then
      perform (p_payload ->> 'periodStart')::date;
      if not (p_payload ? 'periodStart') then raise exception 'invalid_payload: periodStart is required' using errcode = '22023'; end if;
    when 'correction' then
      if not (p_payload ? 'date') then raise exception 'invalid_payload: date is required' using errcode = '22023'; end if;
      perform (p_payload ->> 'date')::date;
  end case;
end $$;

create or replace function public.submit_request(p_organization_id uuid, p_kind public.request_kind, p_payload jsonb default '{}'::jsonb)
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
  if v_user is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not app.has_permission(p_organization_id, v_permission, v_user) then raise exception 'forbidden' using errcode = '42501'; end if;
  perform app.validate_request_payload(p_organization_id, p_kind, p_payload);

  foreach v_ancestor in array app.manager_chain(p_organization_id, v_user) loop
    if app.has_role(p_organization_id, v_ancestor, array['manager', 'executive', 'owner']) then
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
  values (p_organization_id, v_user, p_kind, p_payload) returning * into v_request;
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

create or replace function public.decide_request(p_request_id uuid, p_decision text, p_reason text default null)
returns public.approval_requests
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_request public.approval_requests;
  v_current public.approval_steps;
  v_final public.approval_steps;
  v_acting smallint;
  v_override boolean := false;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if v_user is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if p_decision not in ('approve', 'return') then raise exception 'invalid decision' using errcode = '22023'; end if;

  select * into v_request from public.approval_requests where id = p_request_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_request.status <> 'pending' then raise exception 'closed: request already decided' using errcode = 'P0001'; end if;
  if v_request.requester_id = v_user then
    raise exception 'self_approval: you cannot decide your own request' using errcode = '42501';
  end if;
  if p_decision = 'return' and v_reason is null then raise exception 'reason_required' using errcode = 'P0001'; end if;
  if not app.is_member(v_request.organization_id) then raise exception 'inactive_membership' using errcode = '42501'; end if;

  select * into v_current from public.approval_steps where request_id = p_request_id and status = 'pending' order by position limit 1;
  select * into v_final from public.approval_steps where request_id = p_request_id order by position desc limit 1;

  if v_current.approver_id = v_user then
    v_acting := v_current.position;
  elsif v_final.approver_id = v_user then
    v_acting := v_final.position;
  elsif app.has_permission(v_request.organization_id, 'org.manage') then
    v_acting := v_final.position; -- organization owner override
    v_override := true;
  else
    raise exception 'not_approver' using errcode = '42501';
  end if;

  update public.approval_steps set status = 'skipped'
  where request_id = p_request_id and position < v_acting and status in ('waiting', 'pending');
  update public.approval_steps
  set status = case when p_decision = 'approve' then 'approved'::public.step_status else 'returned'::public.step_status end,
      decided_by = v_user, decided_at = now(), reason = v_reason
  where request_id = p_request_id and position = v_acting;

  if p_decision = 'approve' and v_acting < v_final.position then
    update public.approval_steps set status = 'pending' where request_id = p_request_id and position = v_acting + 1 and status = 'waiting';
  else
    update public.approval_requests
    set status = case when p_decision = 'approve' then 'approved'::public.request_status else 'returned'::public.request_status end,
        decided_at = now()
    where id = p_request_id;
  end if;

  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_request.organization_id, v_user, 'request.' || p_decision, 'approval_request', p_request_id::text,
          jsonb_build_object('step', v_acting, 'reason', v_reason, 'override', v_override));
  select * into v_request from public.approval_requests where id = p_request_id;
  return v_request;
end $$;

-- ---------------------------------------------------------------------------
-- Employee management
-- ---------------------------------------------------------------------------
-- Does the caller hold every grant of p_role_id at least as widely?
create function app.covers_role(p_org uuid, p_role_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  with me as (select id from app.active_membership(p_org)),
       mine as (
         select a.permission, a.scope from public.membership_roles mr
         join public.role_grants a on a.role_id = mr.role_id
         where mr.membership_id = (select id from me)
         union all
         select d.permission, d.scope from public.delegations d
         where d.membership_id = (select id from me) and now() >= d.starts_at and now() < d.expires_at
       )
  select exists (select 1 from me) and not exists (
    select 1 from public.role_grants g
    where g.role_id = p_role_id
      and not exists (select 1 from mine where mine.permission = g.permission and mine.scope >= g.scope)
  )
$$;

create function app.active_owner_count(p_org uuid) returns integer
language sql stable security definer set search_path = '' as $$
  select count(distinct m.id)::integer from public.memberships m
  join public.membership_roles mr on mr.membership_id = m.id
  join public.roles r on r.id = mr.role_id
  where m.organization_id = p_org and m.status = 'active' and r.key = 'owner'
$$;

create function public.assign_role(p_membership_id uuid, p_role_key text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_target public.memberships;
  v_role public.roles;
begin
  select * into v_target from public.memberships where id = p_membership_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if not (app.has_permission(v_target.organization_id, 'admin.roles') or app.has_permission(v_target.organization_id, 'people.manage')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_target.user_id = auth.uid() then raise exception 'self_assignment' using errcode = '42501'; end if;
  select * into v_role from public.roles
  where key = p_role_key and (organization_id is null or organization_id = v_target.organization_id)
  order by organization_id nulls last limit 1;
  if not found then raise exception 'unknown role' using errcode = '22023'; end if;
  if not app.covers_role(v_target.organization_id, v_role.id) then
    raise exception 'escalation: you can only assign roles whose permissions you hold' using errcode = '42501';
  end if;
  if p_role_key <> 'owner' and app.has_role(v_target.organization_id, v_target.user_id, array['owner'])
     and app.active_owner_count(v_target.organization_id) <= 1 then
    raise exception 'last_owner' using errcode = 'P0001';
  end if;
  delete from public.membership_roles where membership_id = p_membership_id;
  insert into public.membership_roles (membership_id, role_id) values (p_membership_id, v_role.id);
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_target.organization_id, auth.uid(), 'member.role_assigned', 'membership', p_membership_id::text, jsonb_build_object('role', p_role_key));
end $$;

create function public.add_member(p_organization_id uuid, p_user_id uuid, p_role_key text, p_reports_to uuid default null, p_department_id uuid default null)
returns public.memberships
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.memberships;
  v_role public.roles;
begin
  if not app.has_permission(p_organization_id, 'people.manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into v_role from public.roles
  where key = p_role_key and (organization_id is null or organization_id = p_organization_id)
  order by organization_id nulls last limit 1;
  if not found then raise exception 'unknown role' using errcode = '22023'; end if;
  if not app.covers_role(p_organization_id, v_role.id) then
    raise exception 'escalation: you can only assign roles whose permissions you hold' using errcode = '42501';
  end if;
  insert into public.memberships (organization_id, user_id, status, department_id, reports_to)
  values (p_organization_id, p_user_id, 'active', p_department_id, p_reports_to) returning * into v_member;
  insert into public.membership_roles (membership_id, role_id) values (v_member.id, v_role.id);
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (p_organization_id, auth.uid(), 'member.added', 'membership', v_member.id::text, jsonb_build_object('role', p_role_key));
  return v_member;
end $$;

create function public.offboard_member(p_membership_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_target public.memberships;
begin
  select * into v_target from public.memberships where id = p_membership_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if not app.has_permission(v_target.organization_id, 'people.offboard', v_target.user_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_target.user_id = auth.uid() then raise exception 'self_offboarding' using errcode = '42501'; end if;
  if v_target.status <> 'active' then raise exception 'already_inactive' using errcode = 'P0001'; end if;
  if app.has_role(v_target.organization_id, v_target.user_id, array['owner']) and app.active_owner_count(v_target.organization_id) <= 1 then
    raise exception 'last_owner' using errcode = 'P0001';
  end if;
  -- Never orphan anyone: direct reports move up to the departing person's manager.
  update public.memberships set reports_to = v_target.reports_to where reports_to = v_target.id;
  update public.memberships set status = 'ended' where id = p_membership_id;
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_target.organization_id, auth.uid(), 'member.offboarded', 'membership', p_membership_id::text, '{}'::jsonb);
end $$;

revoke all on function app.validate_request_payload(uuid, public.request_kind, jsonb), app.covers_role(uuid, uuid), app.active_owner_count(uuid) from public;
grant execute on function app.validate_request_payload(uuid, public.request_kind, jsonb), app.covers_role(uuid, uuid), app.active_owner_count(uuid) to authenticated;
revoke all on function public.assign_role(uuid, text), public.add_member(uuid, uuid, text, uuid, uuid), public.offboard_member(uuid) from public;
grant execute on function public.assign_role(uuid, text), public.add_member(uuid, uuid, text, uuid, uuid), public.offboard_member(uuid) to authenticated;
