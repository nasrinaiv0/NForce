-- =============================================================================
-- NForce · Access model v3: hierarchy and organization access hardening.
-- Mirrors @nforce/core (access/members.ts, approvals/chain.ts).
--
-- * Approval authority follows the reporting line. Executives approve for
--   their direct and indirect reports ("team" scope), including attendance
--   corrections, instead of organization-wide.
-- * decide_request() now checks the approver still holds the approval
--   permission for that requester (a demoted approver can no longer decide).
-- * Requests from the top of the organization (or anyone with no manager-tier
--   approver above them) go to another organization owner.
-- * Pending requests are re-routed whenever the organization changes
--   (offboarding, reporting-line or role changes); a departed person's own
--   pending requests are cancelled.
-- * Only an owner can edit, re-role or offboard an owner. A role change needs
--   the caller to cover BOTH the current and the new role (no demoting someone
--   with more access than you). Nobody manages themselves.
-- * New update_member() RPC for reporting line and department changes.
-- * Correction requests are viewed with attendance.view (was timesheet.view).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Role template grants (authoritative: last block; generated from core)
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
  ('executive', 'timeoff.approve', 'team'),
  ('executive', 'timesheet.approve', 'team'),
  ('executive', 'attendance.correct', 'team'),
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
-- Approval helpers
-- ---------------------------------------------------------------------------
create or replace function app.request_view_permission(p_kind public.request_kind) returns text
language sql immutable set search_path = '' as $$
  select case when p_kind in ('leave', 'day_off') then 'timeoff.view'
              when p_kind = 'correction' then 'attendance.view'
              else 'timesheet.view' end
$$;

create function app.request_decide_permission(p_kind public.request_kind) returns text
language sql immutable set search_path = '' as $$
  select case when p_kind in ('leave', 'day_off') then 'timeoff.approve'
              when p_kind = 'correction' then 'attendance.correct'
              else 'timesheet.approve' end
$$;

-- Approvers for p_user's requests right now: nearest supervisor (review) and
-- nearest manager-tier person (final); another owner when nobody above can
-- finalize. manager_id is null when nobody can approve.
create function app.route_approvers(p_org uuid, p_user uuid, out supervisor_id uuid, out manager_id uuid)
language plpgsql stable security definer set search_path = '' as $$
declare v_ancestor uuid;
begin
  foreach v_ancestor in array app.manager_chain(p_org, p_user) loop
    if app.has_role(p_org, v_ancestor, array['manager', 'executive', 'owner']) then
      manager_id := v_ancestor;
      exit;
    end if;
    if supervisor_id is null and app.has_role(p_org, v_ancestor, array['supervisor']) then
      supervisor_id := v_ancestor;
    end if;
  end loop;
  if manager_id is null then
    select m.user_id into manager_id from public.memberships m
    where m.organization_id = p_org and m.user_id <> p_user and app.has_role(p_org, m.user_id, array['owner'])
    order by m.user_id limit 1;
  end if;
end $$;

-- Re-route every pending request in p_org to the current reporting line.
-- Decided steps stay; a finished supervisor review is not asked again.
-- Requests from people who are no longer active are cancelled.
create function app.reroute_pending_requests(p_org uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_sup uuid;
  v_mgr uuid;
  v_reviewed boolean;
  v_expected text;
  v_actual text;
  v_pos smallint;
  v_changed integer := 0;
begin
  for r in
    select q.id, q.requester_id, m.status as member_status
    from public.approval_requests q
    join public.memberships m on m.organization_id = q.organization_id and m.user_id = q.requester_id
    where q.organization_id = p_org and q.status = 'pending'
    order by q.created_at
    for update of q
  loop
    if r.member_status <> 'active' then
      update public.approval_steps set status = 'skipped' where request_id = r.id and status in ('pending', 'waiting');
      update public.approval_requests set status = 'cancelled', decided_at = now() where id = r.id;
      v_changed := v_changed + 1;
      continue;
    end if;

    select a.supervisor_id, a.manager_id into v_sup, v_mgr from app.route_approvers(p_org, r.requester_id) a;
    if v_mgr is null then continue; end if; -- nobody can approve; owners can still override
    select exists (
      select 1 from public.approval_steps where request_id = r.id and level = 'supervisor' and status in ('approved', 'skipped')
    ) into v_reviewed;
    if v_reviewed then v_sup := null; end if;

    v_expected := concat_ws(',',
      case when v_sup is not null then 'supervisor:' || v_sup || ':pending' end,
      'manager:' || v_mgr || ':' || case when v_sup is null then 'pending' else 'waiting' end);
    select string_agg(level || ':' || approver_id || ':' || status, ',' order by position) into v_actual
    from public.approval_steps where request_id = r.id and status in ('pending', 'waiting');
    if v_actual is not distinct from v_expected then continue; end if;

    delete from public.approval_steps where request_id = r.id and status in ('pending', 'waiting');
    select coalesce(max(position), 0) + 1 into v_pos from public.approval_steps where request_id = r.id;
    if v_sup is not null then
      insert into public.approval_steps (request_id, position, organization_id, level, approver_id, status)
      values (r.id, v_pos, p_org, 'supervisor', v_sup, 'pending');
      v_pos := v_pos + 1;
    end if;
    insert into public.approval_steps (request_id, position, organization_id, level, approver_id, status)
    values (r.id, v_pos, p_org, 'manager', v_mgr,
            case when v_sup is null then 'pending'::public.step_status else 'waiting'::public.step_status end);
    v_changed := v_changed + 1;
  end loop;
  return v_changed;
end $$;

-- ---------------------------------------------------------------------------
-- Requests: routing with owner fallback; approver authority re-checked
-- ---------------------------------------------------------------------------
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
  v_request public.approval_requests;
  v_pos smallint := 1;
begin
  if v_user is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not app.has_permission(p_organization_id, v_permission, v_user) then raise exception 'forbidden' using errcode = '42501'; end if;
  perform app.validate_request_payload(p_organization_id, p_kind, p_payload);

  select a.supervisor_id, a.manager_id into v_supervisor, v_manager from app.route_approvers(p_organization_id, v_user) a;
  if v_manager is null then
    raise exception 'no_approver: set a manager for this person or add a second organization owner' using errcode = 'P0001';
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
  -- Being named on a step is not enough: the approver must still hold the
  -- approval permission at a scope that reaches the requester.
  if not app.has_permission(v_request.organization_id, app.request_decide_permission(v_request.kind), v_request.requester_id) then
    raise exception 'forbidden: you no longer have approval access for this person' using errcode = '42501';
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
-- Member management: protected owners, no demotion of more-privileged people
-- ---------------------------------------------------------------------------
-- Common checks for acting on another member. Raises on failure.
create function app.assert_can_manage(p_target public.memberships, p_permissions text[]) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_target.user_id = auth.uid() then
    raise exception 'self_management: you cannot manage your own membership' using errcode = '42501';
  end if;
  if not exists (select 1 from unnest(p_permissions) p where app.has_permission(p_target.organization_id, p, p_target.user_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if app.has_role(p_target.organization_id, p_target.user_id, array['owner'])
     and not app.has_permission(p_target.organization_id, 'org.manage') then
    raise exception 'protected_member: only an owner can manage an owner' using errcode = '42501';
  end if;
end $$;

create or replace function public.assign_role(p_membership_id uuid, p_role_key text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_target public.memberships;
  v_role public.roles;
begin
  select * into v_target from public.memberships where id = p_membership_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_target.status <> 'active' then raise exception 'already_inactive' using errcode = 'P0001'; end if;
  perform app.assert_can_manage(v_target, array['people.manage', 'admin.roles']);
  select * into v_role from public.roles
  where key = p_role_key and (organization_id is null or organization_id = v_target.organization_id)
  order by organization_id nulls last limit 1;
  if not found then raise exception 'unknown role' using errcode = '22023'; end if;
  if not app.covers_role(v_target.organization_id, v_role.id) then
    raise exception 'escalation: you can only assign roles whose permissions you hold' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.membership_roles mr
    where mr.membership_id = p_membership_id and not app.covers_role(v_target.organization_id, mr.role_id)
  ) then
    raise exception 'escalation: this person has access you do not hold' using errcode = '42501';
  end if;
  if p_role_key <> 'owner' and app.has_role(v_target.organization_id, v_target.user_id, array['owner'])
     and app.active_owner_count(v_target.organization_id) <= 1 then
    raise exception 'last_owner' using errcode = 'P0001';
  end if;
  delete from public.membership_roles where membership_id = p_membership_id;
  insert into public.membership_roles (membership_id, role_id) values (p_membership_id, v_role.id);
  perform app.reroute_pending_requests(v_target.organization_id);
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_target.organization_id, auth.uid(), 'member.role_assigned', 'membership', p_membership_id::text,
          jsonb_build_object('role', p_role_key));
end $$;

create or replace function public.add_member(p_organization_id uuid, p_user_id uuid, p_role_key text, p_reports_to uuid default null, p_department_id uuid default null)
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
  if p_reports_to is not null and not exists (
    select 1 from public.memberships where id = p_reports_to and organization_id = p_organization_id and status = 'active'
  ) then
    raise exception 'invalid manager: choose an active member of this organization' using errcode = '22023';
  end if;
  insert into public.memberships (organization_id, user_id, status, department_id, reports_to)
  values (p_organization_id, p_user_id, 'active', p_department_id, p_reports_to) returning * into v_member;
  insert into public.membership_roles (membership_id, role_id) values (v_member.id, v_role.id);
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (p_organization_id, auth.uid(), 'member.added', 'membership', v_member.id::text, jsonb_build_object('role', p_role_key));
  return v_member;
end $$;

-- Change someone's reporting line and department.
create function public.update_member(p_membership_id uuid, p_reports_to uuid, p_department_id uuid default null)
returns public.memberships
language plpgsql security definer set search_path = '' as $$
declare v_target public.memberships;
begin
  select * into v_target from public.memberships where id = p_membership_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_target.status <> 'active' then raise exception 'already_inactive' using errcode = 'P0001'; end if;
  perform app.assert_can_manage(v_target, array['people.manage']);
  if p_reports_to is not null and not exists (
    select 1 from public.memberships where id = p_reports_to and organization_id = v_target.organization_id and status = 'active'
  ) then
    raise exception 'invalid manager: choose an active member of this organization' using errcode = '22023';
  end if;
  update public.memberships set reports_to = p_reports_to, department_id = p_department_id
  where id = p_membership_id returning * into v_target; -- the cycle trigger rejects loops
  perform app.reroute_pending_requests(v_target.organization_id);
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_target.organization_id, auth.uid(), 'member.updated', 'membership', p_membership_id::text,
          jsonb_build_object('reportsTo', p_reports_to, 'departmentId', p_department_id));
  return v_target;
end $$;

create or replace function public.offboard_member(p_membership_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_target public.memberships;
begin
  select * into v_target from public.memberships where id = p_membership_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_target.user_id = auth.uid() then raise exception 'self_offboarding' using errcode = '42501'; end if;
  if v_target.status <> 'active' then raise exception 'already_inactive' using errcode = 'P0001'; end if;
  perform app.assert_can_manage(v_target, array['people.offboard']);
  if app.has_role(v_target.organization_id, v_target.user_id, array['owner']) and app.active_owner_count(v_target.organization_id) <= 1 then
    raise exception 'last_owner' using errcode = 'P0001';
  end if;
  -- Never orphan anyone: direct reports move up to the departing person's manager.
  update public.memberships set reports_to = v_target.reports_to where reports_to = v_target.id;
  update public.memberships set status = 'ended' where id = p_membership_id;
  -- Their own pending requests are cancelled; requests waiting on them move on.
  perform app.reroute_pending_requests(v_target.organization_id);
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_target.organization_id, auth.uid(), 'member.offboarded', 'membership', p_membership_id::text, '{}'::jsonb);
end $$;

revoke all on function app.request_decide_permission(public.request_kind), app.route_approvers(uuid, uuid),
  app.reroute_pending_requests(uuid), app.assert_can_manage(public.memberships, text[]) from public;
revoke all on function public.update_member(uuid, uuid, uuid) from public;
grant execute on function public.update_member(uuid, uuid, uuid) to authenticated;
