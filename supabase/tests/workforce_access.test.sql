-- Phase 3 + access model v2: department separation, owner superiority,
-- no privilege escalation, offboarding, timesheets→payroll lock, leave ledger,
-- notifications, CRM and aggregate-only executive reporting.
\set ON_ERROR_STOP on
begin;

create function pg_temp.expect(ok boolean, label text) returns void language plpgsql as $$
begin
  if not ok then raise exception 'FAILED: %', label; end if;
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

-- People: owner ← vp ← mgr ← sup ← staff/staff2 ; owner ← hr, payroll, it
insert into auth.users (id) select ('c0000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid from generate_series(1, 10) n;
insert into public.organizations (id, name, time_zone) values ('c1000000-0000-0000-0000-000000000001', 'Northwind', 'Asia/Manila');
insert into public.departments (id, organization_id, name) values
  ('c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'Operations'),
  ('c2000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001', 'People');
create temp table who (name text primary key, uid uuid, mid uuid, role text, boss text, dept uuid);
insert into who values
  ('owner',  'c0000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000001', 'owner', null, 'c2000000-0000-0000-0000-000000000001'),
  ('vp',     'c0000000-0000-0000-0000-000000000002', 'c3000000-0000-0000-0000-000000000002', 'executive', 'owner', 'c2000000-0000-0000-0000-000000000001'),
  ('mgr',    'c0000000-0000-0000-0000-000000000003', 'c3000000-0000-0000-0000-000000000003', 'manager', 'vp', 'c2000000-0000-0000-0000-000000000001'),
  ('sup',    'c0000000-0000-0000-0000-000000000004', 'c3000000-0000-0000-0000-000000000004', 'supervisor', 'mgr', 'c2000000-0000-0000-0000-000000000001'),
  ('staff',  'c0000000-0000-0000-0000-000000000005', 'c3000000-0000-0000-0000-000000000005', 'staff', 'sup', 'c2000000-0000-0000-0000-000000000001'),
  ('staff2', 'c0000000-0000-0000-0000-000000000006', 'c3000000-0000-0000-0000-000000000006', 'staff', 'sup', 'c2000000-0000-0000-0000-000000000001'),
  ('hr',     'c0000000-0000-0000-0000-000000000007', 'c3000000-0000-0000-0000-000000000007', 'hr', 'owner', 'c2000000-0000-0000-0000-000000000002'),
  ('payroll','c0000000-0000-0000-0000-000000000008', 'c3000000-0000-0000-0000-000000000008', 'payroll', 'owner', null),
  ('it',     'c0000000-0000-0000-0000-000000000009', 'c3000000-0000-0000-0000-000000000009', 'org_admin', 'owner', null);
grant select on who to authenticated;
insert into public.memberships (id, organization_id, user_id, status, department_id)
select mid, 'c1000000-0000-0000-0000-000000000001', uid, 'active', dept from who;
update public.memberships m set reports_to = b.mid from who w join who b on b.name = w.boss where m.id = w.mid;
insert into public.membership_roles (membership_id, role_id)
select w.mid, r.id from who w join public.roles r on r.organization_id is null and r.key = w.role;
insert into public.leave_types (organization_id, key, name) values ('c1000000-0000-0000-0000-000000000001', 'vacation', 'Vacation');
insert into public.leave_transactions (organization_id, user_id, leave_type, kind, days)
values ('c1000000-0000-0000-0000-000000000001', (select uid from who where name = 'staff'), 'vacation', 'accrual', 15);

create function pg_temp.u(n text) returns uuid language sql as $$ select uid from who where name = n $$;
create function pg_temp.m(n text) returns uuid language sql as $$ select mid from who where name = n $$;
create function pg_temp.org() returns uuid language sql as $$ select 'c1000000-0000-0000-0000-000000000001'::uuid $$;

-- Attendance for reporting and department visibility.
select pg_temp.act_as(pg_temp.u('staff'));
select public.record_attendance_event(pg_temp.org(), 'clock_in', 'staff-key-0001');
reset role;

-- ---------------------------------------------------------------- department separation
select pg_temp.act_as(pg_temp.u('hr'));
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events) = 1, 'HR can read attendance org-wide');
  perform pg_temp.expect(not app.has_permission(pg_temp.org(), 'payroll.view'), 'HR has no payroll access');
end $$;
select pg_temp.raises($$ select public.lock_payroll_period(pg_temp.org(), '2026-11-16') $$, '42501', 'HR cannot lock payroll');
reset role;
select pg_temp.act_as(pg_temp.u('payroll'));
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events) = 1, 'Payroll can read punches');
  perform pg_temp.expect(not app.has_permission(pg_temp.org(), 'people.view.sensitive'), 'Payroll has no confidential HR access');
end $$;
select pg_temp.raises($$ select public.offboard_member(pg_temp.m('staff2')) $$, '42501', 'Payroll cannot offboard employees');
reset role;
select pg_temp.act_as(pg_temp.u('it'));
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events) = 0, 'IT admin sees no attendance data');
end $$;
reset role;

-- ---------------------------------------------------------------- request validation
select pg_temp.act_as(pg_temp.u('staff'));
select pg_temp.raises($$ select public.submit_request(pg_temp.org(), 'leave', '{"start":"2026-12-01","end":"2026-12-02"}') $$, '22023', 'leave without type/days is rejected');
select pg_temp.raises($$ select public.submit_request(pg_temp.org(), 'leave', '{"leaveTypeId":"nope","start":"2026-12-01","end":"2026-12-02","days":2}') $$, '22023', 'unknown leave type is rejected');
select pg_temp.raises($$ select public.submit_request(pg_temp.org(), 'overtime', '{"date":"2026-11-17","minutes":5}') $$, '22023', 'overtime under 15 minutes is rejected');
create temp table req (name text primary key, id uuid);
grant all on req to authenticated;
insert into req select 'leave', (public.submit_request(pg_temp.org(), 'leave', '{"leaveTypeId":"vacation","start":"2026-12-01","end":"2026-12-03","days":3}')).id;
insert into req select 'ts', (public.submit_timesheet(pg_temp.org(), '2026-11-16', 2400, 90)).id;
do $$ begin
  perform pg_temp.expect((select status from public.timesheets where id = (select id from req where name = 'ts')) = 'submitted', 'submit_timesheet moves the sheet to submitted');
end $$;
reset role;

-- ---------------------------------------------------------------- notifications
select pg_temp.act_as(pg_temp.u('sup'));
do $$ begin
  perform pg_temp.expect((select count(*) from public.notifications where kind = 'approval_needed') >= 2, 'supervisor is notified of pending steps');
end $$;
reset role;
select pg_temp.act_as(pg_temp.u('staff2'));
do $$ begin
  perform pg_temp.expect((select count(*) from public.notifications) = 0, 'people only see their own notifications');
end $$;
reset role;

-- ---------------------------------------------------------------- owner superiority
select pg_temp.act_as(pg_temp.u('owner'));
do $$
declare v_leave uuid := (select id from req where name = 'leave');
begin
  perform public.decide_request(v_leave, 'approve');
  perform pg_temp.expect((select status from public.approval_requests where id = v_leave) = 'approved', 'owner approves any request at any stage');
  perform pg_temp.expect(
    (select array_agg(status::text order by position) from public.approval_steps where request_id = v_leave) = array['skipped', 'approved'],
    'owner override skips the pending review');
  perform pg_temp.expect((select (data ->> 'override')::boolean from public.audit_events where action = 'request.approve' order by id desc limit 1),
    'the override is recorded in the audit trail');
end $$;
reset role;

select pg_temp.act_as(pg_temp.u('staff'));
do $$ begin
  perform pg_temp.expect((select available_days from public.leave_balances where leave_type = 'vacation') = 12, 'approved leave posts usage to the ledger (15 → 12)');
  perform pg_temp.expect((select count(*) from public.notifications where kind = 'request_decided') = 1, 'requester is notified of the decision');
end $$;
select pg_temp.raises($$ update public.leave_transactions set days = 99 $$, '42501', 'the leave ledger is append-only');
reset role;

select pg_temp.act_as(pg_temp.u('vp'));
do $$ begin
  perform public.submit_request(pg_temp.org(), 'day_off', '{"start":"2026-12-24","end":"2026-12-24"}');
  perform pg_temp.expect(
    (select approver_id from public.approval_steps s join public.approval_requests r on r.id = s.request_id
     where r.requester_id = auth.uid() limit 1) = pg_temp.u('owner'),
    'an executive''s request goes to the owner');
end $$;
reset role;
select pg_temp.act_as(pg_temp.u('owner'));
select pg_temp.raises($$ select public.submit_request(pg_temp.org(), 'day_off', '{"start":"2026-12-24","end":"2026-12-24"}') $$, 'P0001', 'the owner has no approver above them (no self-approval path)');
reset role;

-- ---------------------------------------------------------------- timesheets → payroll lock
select pg_temp.act_as(pg_temp.u('payroll'));
select pg_temp.raises($$ select public.lock_payroll_period(pg_temp.org(), '2026-11-16') $$, 'P0001', 'payroll cannot lock while a timesheet is not approved');
reset role;
select pg_temp.act_as(pg_temp.u('mgr'));
do $$ begin
  perform public.decide_request((select r.id from public.approval_requests r where r.kind = 'timesheet' limit 1), 'approve');
  perform pg_temp.expect((select status from public.timesheets limit 1) = 'approved', 'manager final approval updates the timesheet');
end $$;
reset role;
select pg_temp.act_as(pg_temp.u('payroll'));
do $$ begin
  perform public.lock_payroll_period(pg_temp.org(), '2026-11-16');
  perform pg_temp.expect((select status from public.timesheets limit 1) = 'locked', 'locking the period locks approved timesheets');
end $$;
select pg_temp.raises($$ select public.lock_payroll_period(pg_temp.org(), '2026-11-16') $$, 'P0001', 'a period can only be locked once');
reset role;
select pg_temp.raises($$ update public.timesheets set worked_minutes = 1 $$, '42501', 'locked timesheets are immutable');

-- ---------------------------------------------------------------- role assignment & offboarding
select pg_temp.act_as(pg_temp.u('hr'));
do $$ begin
  perform public.assign_role(pg_temp.m('staff2'), 'staff');
  perform pg_temp.expect(true, 'HR can assign the staff role');
end $$;
select pg_temp.raises($$ select public.assign_role(pg_temp.m('staff2'), 'payroll') $$, '42501', 'HR cannot grant payroll (no escalation)');
select pg_temp.raises($$ select public.assign_role(pg_temp.m('hr'), 'staff') $$, '42501', 'nobody changes their own role');
reset role;
select pg_temp.act_as(pg_temp.u('it'));
select pg_temp.raises($$ select public.assign_role(pg_temp.m('staff2'), 'supervisor') $$, '42501', 'IT admin cannot grant business roles');
reset role;
select pg_temp.act_as(pg_temp.u('owner'));
do $$ begin
  perform public.assign_role(pg_temp.m('staff2'), 'supervisor');
  perform pg_temp.expect(app.has_role(pg_temp.org(), pg_temp.u('staff2'), array['supervisor']), 'the owner can assign any role');
end $$;
select pg_temp.raises($$ select public.assign_role(pg_temp.m('owner'), 'staff') $$, '42501', 'the owner cannot demote themselves');
reset role;
select pg_temp.act_as(pg_temp.u('hr'));
do $$ begin
  perform public.offboard_member(pg_temp.m('sup'));
  perform pg_temp.expect((select status from public.memberships where id = pg_temp.m('sup')) = 'ended', 'HR can offboard an employee');
  perform pg_temp.expect((select reports_to from public.memberships where id = pg_temp.m('staff')) = pg_temp.m('mgr'), 'their reports move up to the departing manager''s manager');
end $$;
select pg_temp.raises($$ select public.offboard_member(pg_temp.m('owner')) $$, 'P0001', 'the last owner cannot be offboarded');
select pg_temp.raises($$ select public.offboard_member(pg_temp.m('hr')) $$, '42501', 'nobody offboards themselves');
reset role;
select pg_temp.act_as(pg_temp.u('sup'));
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events) = 0, 'an offboarded person loses all access');
end $$;
reset role;

-- ---------------------------------------------------------------- CRM
insert into public.crm_accounts (id, organization_id, name) values ('c4000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'Meridian');
insert into public.crm_deals (id, organization_id, account_id, name, stage, amount_minor) values
  ('c5000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000001', 'Renewal', 'proposal', 480000000);
select pg_temp.act_as(pg_temp.u('vp'));
do $$ begin perform pg_temp.expect((select count(*) from public.crm_deals) = 1, 'executives can read the pipeline'); end $$;
select pg_temp.raises($$ select public.move_deal('c5000000-0000-0000-0000-000000000001', 'negotiation') $$, '42501', 'executives cannot change deals');
reset role;
select pg_temp.act_as(pg_temp.u('staff'));
do $$ begin perform pg_temp.expect((select count(*) from public.crm_deals) = 0, 'staff cannot read the pipeline'); end $$;
reset role;
select pg_temp.act_as(pg_temp.u('owner'));
select pg_temp.raises($$ select public.move_deal('c5000000-0000-0000-0000-000000000001', 'lost') $$, 'P0001', 'losing a deal needs a reason');
do $$ begin
  perform public.move_deal('c5000000-0000-0000-0000-000000000001', 'won');
  perform pg_temp.expect((select stage from public.crm_deals) = 'won', 'the owner can move deals');
end $$;
select pg_temp.raises($$ select public.move_deal('c5000000-0000-0000-0000-000000000001', 'proposal') $$, 'P0001', 'closed deals cannot move');

-- ---------------------------------------------------------------- aggregate reporting
do $$
declare v_groups text[];
begin
  select array_agg(group_name order by group_name) into v_groups from public.report_attendance_summary(pg_temp.org(), current_date - 30, current_date);
  perform pg_temp.expect(v_groups = array['Operations', 'Other'], 'groups under 3 people are folded into Other');
  perform pg_temp.expect(
    (select present_person_days from public.report_attendance_summary(pg_temp.org(), current_date - 30, current_date) where group_name = 'Operations') = 1,
    'the summary counts present person-days');
end $$;
reset role;
select pg_temp.act_as(pg_temp.u('staff'));
select pg_temp.raises($$ select * from public.report_attendance_summary(pg_temp.org(), current_date - 30, current_date) $$, '42501', 'staff cannot run organization reports');
reset role;

rollback;
