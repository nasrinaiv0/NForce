-- Access model v3: approval authority follows the reporting line, owners are
-- protected, nobody demotes someone with more access, and pending requests are
-- re-routed when the organization changes. Plus tenant isolation.
\set ON_ERROR_STOP on
begin;

create function pg_temp.expect(ok boolean, label text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAILED: %', label; end if;
  raise notice 'ok - %', label;
end $$;
create function pg_temp.act_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(uid::text, ''), true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.raises(stmt text, state text, label text) returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAILED: % (no error)', label;
exception when others then
  if sqlstate = state or sqlerrm like state || '%' then raise notice 'ok - %', label;
  else raise exception 'FAILED: % (got % %)', label, sqlstate, sqlerrm; end if;
end $$;

-- Org A:  owner ← vp ← mgr ← sup  ← staff, staff2
--                        mgr ← sup2 ← staff3
--         owner ← hr, payroll, it
-- Org B:  outsider (owner)
insert into auth.users (id) select ('d0000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid from generate_series(1, 12) n;
insert into public.organizations (id, name, time_zone) values
  ('d1000000-0000-0000-0000-000000000001', 'Northwind', 'Asia/Manila'),
  ('d1000000-0000-0000-0000-000000000002', 'Contoso', 'Asia/Manila');
insert into public.departments (id, organization_id, name) values
  ('d2000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'Operations'),
  ('d2000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000001', 'People');
create temp table who (name text primary key, uid uuid, mid uuid, org uuid, role text, boss text, dept uuid);
insert into who values
  ('owner',   'd0000000-0000-0000-0000-000000000001', 'd3000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'owner', null, 'd2000000-0000-0000-0000-000000000001'),
  ('vp',      'd0000000-0000-0000-0000-000000000002', 'd3000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000001', 'executive', 'owner', 'd2000000-0000-0000-0000-000000000001'),
  ('mgr',     'd0000000-0000-0000-0000-000000000003', 'd3000000-0000-0000-0000-000000000003', 'd1000000-0000-0000-0000-000000000001', 'manager', 'vp', 'd2000000-0000-0000-0000-000000000001'),
  ('sup',     'd0000000-0000-0000-0000-000000000004', 'd3000000-0000-0000-0000-000000000004', 'd1000000-0000-0000-0000-000000000001', 'supervisor', 'mgr', 'd2000000-0000-0000-0000-000000000001'),
  ('staff',   'd0000000-0000-0000-0000-000000000005', 'd3000000-0000-0000-0000-000000000005', 'd1000000-0000-0000-0000-000000000001', 'staff', 'sup', 'd2000000-0000-0000-0000-000000000001'),
  ('staff2',  'd0000000-0000-0000-0000-000000000006', 'd3000000-0000-0000-0000-000000000006', 'd1000000-0000-0000-0000-000000000001', 'staff', 'sup', 'd2000000-0000-0000-0000-000000000001'),
  ('sup2',    'd0000000-0000-0000-0000-000000000007', 'd3000000-0000-0000-0000-000000000007', 'd1000000-0000-0000-0000-000000000001', 'supervisor', 'mgr', 'd2000000-0000-0000-0000-000000000001'),
  ('staff3',  'd0000000-0000-0000-0000-000000000008', 'd3000000-0000-0000-0000-000000000008', 'd1000000-0000-0000-0000-000000000001', 'staff', 'sup2', 'd2000000-0000-0000-0000-000000000001'),
  ('hr',      'd0000000-0000-0000-0000-000000000009', 'd3000000-0000-0000-0000-000000000009', 'd1000000-0000-0000-0000-000000000001', 'hr', 'owner', 'd2000000-0000-0000-0000-000000000002'),
  ('payroll', 'd0000000-0000-0000-0000-000000000010', 'd3000000-0000-0000-0000-000000000010', 'd1000000-0000-0000-0000-000000000001', 'payroll', 'owner', null),
  ('it',      'd0000000-0000-0000-0000-000000000011', 'd3000000-0000-0000-0000-000000000011', 'd1000000-0000-0000-0000-000000000001', 'org_admin', 'owner', null),
  ('outsider','d0000000-0000-0000-0000-000000000012', 'd3000000-0000-0000-0000-000000000012', 'd1000000-0000-0000-0000-000000000002', 'owner', null, null);
grant select on who to authenticated;
insert into public.memberships (id, organization_id, user_id, status, department_id) select mid, org, uid, 'active', dept from who;
update public.memberships m set reports_to = b.mid from who w join who b on b.name = w.boss where m.id = w.mid;
insert into public.membership_roles (membership_id, role_id)
select w.mid, r.id from who w join public.roles r on r.organization_id is null and r.key = w.role;

create function pg_temp.u(n text) returns uuid language sql as $$ select uid from who where name = n $$;
create function pg_temp.m(n text) returns uuid language sql as $$ select mid from who where name = n $$;
create function pg_temp.org() returns uuid language sql as $$ select 'd1000000-0000-0000-0000-000000000001'::uuid $$;
create function pg_temp.steps(p_request uuid) returns text language sql security definer as $$
  select string_agg(s.level || ':' || w.name || ':' || s.status, ' > ' order by s.position)
  from public.approval_steps s join who w on w.uid = s.approver_id where s.request_id = p_request
$$;
create temp table ids (name text primary key, id uuid);
grant select, insert on ids to authenticated;
create function pg_temp.r(n text) returns uuid language sql as $$ select id from ids where name = n $$;
create function pg_temp.submit(p_as text, p_name text, p_kind public.request_kind, p_payload jsonb) returns void language plpgsql as $$
begin
  perform pg_temp.act_as(pg_temp.u(p_as));
  insert into ids select p_name, (public.submit_request(pg_temp.org(), p_kind, p_payload)).id;
  reset role;
end $$;

-- ---------------------------------------------------------------- scope follows the reporting line
select pg_temp.act_as(pg_temp.u('sup'));
do $$ begin
  perform pg_temp.expect(app.has_permission(pg_temp.org(), 'attendance.view', pg_temp.u('staff')), 'a supervisor reaches their direct report');
  perform pg_temp.expect(not app.has_permission(pg_temp.org(), 'attendance.view', pg_temp.u('staff3')), 'a supervisor does not reach a peer supervisor''s report');
  perform pg_temp.expect(not app.has_permission(pg_temp.org(), 'attendance.view', pg_temp.u('mgr')), 'a supervisor does not reach their own manager');
end $$;
reset role;
select pg_temp.act_as(pg_temp.u('mgr'));
do $$ begin
  perform pg_temp.expect(app.has_permission(pg_temp.org(), 'timeoff.approve', pg_temp.u('staff3')), 'a manager reaches indirect reports');
  perform pg_temp.expect(not app.has_permission(pg_temp.org(), 'attendance.view', pg_temp.u('vp')), 'a manager does not look up the line');
end $$;
reset role;
select pg_temp.act_as(pg_temp.u('vp'));
do $$ begin
  perform pg_temp.expect(app.has_permission(pg_temp.org(), 'attendance.correct', pg_temp.u('mgr')), 'an executive can approve corrections for their reports');
  perform pg_temp.expect(app.has_permission(pg_temp.org(), 'timeoff.approve', pg_temp.u('staff3')), 'an executive approves anyone in their line');
  perform pg_temp.expect(not app.has_permission(pg_temp.org(), 'timeoff.approve', pg_temp.u('hr')), 'an executive does not approve outside their line');
  perform pg_temp.expect(not app.has_permission(pg_temp.org(), 'attendance.view', pg_temp.u('staff')), 'an executive does not see person-level attendance');
end $$;
reset role;

-- Monetary confidentiality is independent of reporting-line and HR authority.
-- Enable fictional review gate to distinguish authorization from absent data.
insert into app.accounting_review_access(organization_id,evidence_reference,enabled_by,expires_at) values(pg_temp.org(),'fictional independent review',pg_temp.u('owner'),now()+interval '1 day');
select pg_temp.act_as(pg_temp.u('payroll'));
select pg_temp.raises($$select public.payroll_management_snapshot(pg_temp.org(),'2026-01-12')$$,'P0001','payroll passes role gate but absent monetary data remains blocked');
reset role;
select pg_temp.act_as(pg_temp.u('owner'));
select pg_temp.raises($$select public.payroll_management_snapshot(pg_temp.org(),'2026-01-12')$$,'P0001','owner passes role gate but absent monetary data remains blocked');
reset role;
select pg_temp.act_as(pg_temp.u('staff'));
select pg_temp.raises($$select public.payroll_management_snapshot(pg_temp.org(),'2026-01-12')$$,'42501','staff cannot access management payroll');
reset role;
select pg_temp.act_as(pg_temp.u('sup'));
select pg_temp.raises($$select public.payroll_management_snapshot(pg_temp.org(),'2026-01-12')$$,'42501','supervisor cannot access management payroll');
reset role;
select pg_temp.act_as(pg_temp.u('mgr'));
select pg_temp.raises($$select public.payroll_management_snapshot(pg_temp.org(),'2026-01-12')$$,'42501','department manager cannot access management payroll');
select pg_temp.expect(not app.has_permission(pg_temp.org(),'attendance.view',pg_temp.u('hr')),'manager cannot see another department');
reset role;
select pg_temp.act_as(pg_temp.u('vp'));
select pg_temp.raises($$select public.payroll_management_snapshot(pg_temp.org(),'2026-01-12')$$,'42501','executive aggregate reporting does not grant payroll access');
reset role;
select pg_temp.act_as(pg_temp.u('hr'));
select pg_temp.raises($$select public.payroll_management_snapshot(pg_temp.org(),'2026-01-12')$$,'42501','HR cannot access management payroll');
reset role;
select pg_temp.act_as(pg_temp.u('it'));
select pg_temp.raises($$select public.payroll_management_snapshot(pg_temp.org(),'2026-01-12')$$,'42501','IT administration does not grant payroll access');
reset role;
select pg_temp.act_as(pg_temp.u('outsider'));
select pg_temp.raises($$select public.payroll_self_snapshot(pg_temp.org(),'2026-01-12')$$,'42501','foreign organization owner cannot read personal payroll in another tenant');
reset role;

-- ---------------------------------------------------------------- routing
select pg_temp.submit('mgr', 'mgr_fix', 'correction', '{"date":"2026-11-20"}');
select pg_temp.submit('staff', 'staff_off', 'day_off', '{"start":"2026-12-10","end":"2026-12-10"}');
select pg_temp.submit('staff2', 'staff2_off', 'day_off', '{"start":"2026-12-11","end":"2026-12-11"}');
select pg_temp.submit('staff3', 'staff3_off', 'day_off', '{"start":"2026-12-12","end":"2026-12-12"}');
select pg_temp.submit('hr', 'hr_off', 'day_off', '{"start":"2026-12-14","end":"2026-12-14"}');
do $$ begin
  perform pg_temp.expect(pg_temp.steps(pg_temp.r('mgr_fix')) = 'manager:vp:pending', 'a manager''s correction goes to their executive');
  perform pg_temp.expect(pg_temp.steps(pg_temp.r('staff_off')) = 'supervisor:sup:pending > manager:mgr:waiting', 'staff requests go supervisor → manager');
  perform pg_temp.expect(pg_temp.steps(pg_temp.r('hr_off')) = 'manager:owner:pending', 'requests of people reporting to the owner go to the owner');
end $$;
select pg_temp.act_as(pg_temp.u('vp'));
do $$ begin
  perform public.decide_request(pg_temp.r('mgr_fix'), 'approve');
  perform pg_temp.expect((select status from public.approval_requests where id = pg_temp.r('mgr_fix')) = 'approved', 'the executive approves the manager''s correction');
end $$;
select pg_temp.raises($$ select public.decide_request(pg_temp.r('hr_off'), 'approve') $$, '42501', 'an executive cannot decide outside their line');
reset role;
select pg_temp.act_as(pg_temp.u('sup'));
select pg_temp.raises($$ select public.decide_request(pg_temp.r('staff3_off'), 'approve') $$, '42501', 'a supervisor cannot decide a peer team''s request');
reset role;
select pg_temp.act_as(pg_temp.u('owner'));
select pg_temp.raises($$ select public.submit_request(pg_temp.org(), 'day_off', '{"start":"2026-12-15","end":"2026-12-15"}') $$, 'P0001', 'a sole owner''s request has no approver');
reset role;

-- ---------------------------------------------------------------- correction visibility
select pg_temp.submit('staff', 'staff_fix', 'correction', '{"date":"2026-11-21"}');
select pg_temp.act_as(pg_temp.u('payroll'));
do $$ begin
  perform pg_temp.expect(exists (select 1 from public.approval_requests where id = pg_temp.r('staff_fix')), 'payroll (attendance.view) sees correction requests');
  perform pg_temp.expect(not exists (select 1 from public.approval_requests where id = pg_temp.r('staff_off')), 'payroll does not see time-off requests');
end $$;
reset role;

-- ---------------------------------------------------------------- approver authority is re-checked
-- Simulate a custom role change that bypassed the RPCs: sup keeps the step but loses approval rights.
update public.membership_roles set role_id = (select id from public.roles where organization_id is null and key = 'staff') where membership_id = pg_temp.m('sup');
select pg_temp.act_as(pg_temp.u('sup'));
select pg_temp.raises($$ select public.decide_request(pg_temp.r('staff_off'), 'approve') $$, '42501', 'a step approver without approval rights cannot decide');
reset role;
update public.membership_roles set role_id = (select id from public.roles where organization_id is null and key = 'supervisor') where membership_id = pg_temp.m('sup');

-- ---------------------------------------------------------------- member management
select pg_temp.act_as(pg_temp.u('hr'));
select pg_temp.raises($$ select public.assign_role(pg_temp.m('vp'), 'staff') $$, '42501', 'HR cannot demote an executive (has access HR lacks)');
select pg_temp.raises($$ select public.assign_role(pg_temp.m('owner'), 'hr') $$, '42501', 'HR cannot change the owner''s role');
select pg_temp.raises($$ select public.update_member(pg_temp.m('owner'), pg_temp.m('hr')) $$, '42501', 'HR cannot move the owner');
select pg_temp.raises($$ select public.update_member(pg_temp.m('hr'), pg_temp.m('vp')) $$, '42501', 'nobody changes their own reporting line');
select pg_temp.raises($$ select public.update_member(pg_temp.m('mgr'), pg_temp.m('staff'), 'd2000000-0000-0000-0000-000000000001') $$, '23514', 'reporting loops are rejected');
select pg_temp.raises($$ select public.update_member(pg_temp.m('staff'), pg_temp.m('outsider')) $$, '22023', 'a manager must be in the same organization');
reset role;
select pg_temp.act_as(pg_temp.u('it'));
do $$ begin
  perform public.assign_role(pg_temp.m('staff2'), 'org_admin');
  perform pg_temp.expect(app.has_role(pg_temp.org(), pg_temp.u('staff2'), array['org_admin']), 'IT can grant the IT admin role');
  perform public.assign_role(pg_temp.m('staff2'), 'staff');
end $$;
select pg_temp.raises($$ select public.assign_role(pg_temp.m('sup'), 'staff') $$, '42501', 'IT cannot demote a supervisor (business access it lacks)');
reset role;
select pg_temp.act_as(pg_temp.u('mgr'));
select pg_temp.raises($$ select public.update_member(pg_temp.m('staff'), pg_temp.m('sup2')) $$, '42501', 'managers cannot edit employee records');
reset role;

-- ---------------------------------------------------------------- re-routing on organization changes
-- staff moves from sup to sup2: their pending request follows.
select pg_temp.act_as(pg_temp.u('hr'));
do $$ begin
  perform public.update_member(pg_temp.m('staff'), pg_temp.m('sup2'), 'd2000000-0000-0000-0000-000000000001');
  perform pg_temp.expect(pg_temp.steps(pg_temp.r('staff_off')) = 'supervisor:sup2:pending > manager:mgr:waiting', 'a pending request follows a reporting-line change');
end $$;
reset role;
-- sup reviews staff2's request, then is offboarded: the review stays, the manager decides.
select pg_temp.act_as(pg_temp.u('sup'));
select public.decide_request(pg_temp.r('staff2_off'), 'approve');
reset role;
select pg_temp.act_as(pg_temp.u('hr'));
do $$ begin
  perform public.offboard_member(pg_temp.m('sup'));
  perform pg_temp.expect(pg_temp.steps(pg_temp.r('staff2_off')) = 'supervisor:sup:approved > manager:mgr:pending', 'a completed review is kept when the reviewer leaves');
end $$;
reset role;
-- sup2 is offboarded before reviewing: staff's and staff3's requests go to the manager.
select pg_temp.act_as(pg_temp.u('hr'));
do $$ begin
  perform public.offboard_member(pg_temp.m('sup2'));
  perform pg_temp.expect(pg_temp.steps(pg_temp.r('staff3_off')) = 'manager:mgr:pending', 'requests waiting on a departed approver move up');
  perform pg_temp.expect(position('sup2:skipped' in pg_temp.steps(pg_temp.r('staff_off'))) = 0 and pg_temp.steps(pg_temp.r('staff_off')) = 'manager:mgr:pending', 'no step is left with a departed approver');
end $$;
-- A departing requester's pending requests are cancelled.
do $$ begin
  perform public.offboard_member(pg_temp.m('staff3'));
  perform pg_temp.expect((select status from public.approval_requests where id = pg_temp.r('staff3_off')) = 'cancelled', 'a departed person''s pending requests are cancelled');
end $$;
reset role;
-- The owner demotes the manager: pending requests move to the executive.
select pg_temp.act_as(pg_temp.u('owner'));
do $$ begin
  perform public.assign_role(pg_temp.m('mgr'), 'staff');
  perform pg_temp.expect(pg_temp.steps(pg_temp.r('staff2_off')) = 'supervisor:sup:approved > manager:vp:pending', 'a demoted approver''s pending requests move up');
end $$;
-- With a second owner, an owner's own request goes to them.
do $$ begin
  perform public.assign_role(pg_temp.m('it'), 'owner');
  insert into ids select 'owner_off', (public.submit_request(pg_temp.org(), 'day_off', '{"start":"2026-12-15","end":"2026-12-15"}')).id;
  perform pg_temp.expect(pg_temp.steps(pg_temp.r('owner_off')) = 'manager:it:pending', 'an owner''s request goes to another owner');
end $$;
select pg_temp.raises($$ select public.decide_request(pg_temp.r('owner_off'), 'approve') $$, '42501', 'owners still cannot approve their own requests');
reset role;
select pg_temp.act_as(pg_temp.u('it'));
do $$ begin
  perform public.offboard_member(pg_temp.m('owner'));
  perform pg_temp.expect((select status from public.memberships where id = pg_temp.m('owner')) = 'ended', 'an owner can offboard another owner');
end $$;
select pg_temp.raises($$ select public.assign_role(pg_temp.m('it'), 'staff') $$, '42501', 'the remaining owner cannot change their own role');
reset role;

-- ---------------------------------------------------------------- tenant isolation
select pg_temp.act_as(pg_temp.u('outsider'));
do $$ begin
  perform pg_temp.expect((select count(*) from public.approval_requests) = 0, 'another organization''s owner sees no requests');
  perform pg_temp.expect((select count(*) from public.memberships where organization_id = pg_temp.org()) = 0, 'another organization''s owner sees no members');
end $$;
select pg_temp.raises($$ select public.decide_request(pg_temp.r('staff2_off'), 'approve') $$, '42501', 'another organization''s owner cannot decide requests');
select pg_temp.raises($$ select public.offboard_member(pg_temp.m('vp')) $$, '42501', 'another organization''s owner cannot offboard members');
select pg_temp.raises($$ select public.assign_role(pg_temp.m('vp'), 'staff') $$, '42501', 'another organization''s owner cannot assign roles');
reset role;

rollback;
