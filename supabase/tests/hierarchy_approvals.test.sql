-- Hierarchy & approvals: reporting-line scope, cycle prevention, routing
-- (supervisor review → manager final), manager override, no self-approval.
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

-- vp ← mgr ← sup ← staff ;  mgr ← sup2 ← staff2 (no team rows: reporting line only) ; vp ← hr
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-0000000000a3'), ('00000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000000a5'), ('00000000-0000-0000-0000-0000000000a6'),
  ('00000000-0000-0000-0000-0000000000a7');
insert into public.organizations (id, name, time_zone) values ('10000000-0000-0000-0000-0000000000f1', 'Northwind', 'Asia/Manila');
insert into public.memberships (id, organization_id, user_id, status) values
  ('40000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1', 'active'), -- vp
  ('40000000-0000-0000-0000-0000000000a2', '10000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a2', 'active'), -- mgr
  ('40000000-0000-0000-0000-0000000000a3', '10000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a3', 'active'), -- sup
  ('40000000-0000-0000-0000-0000000000a4', '10000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a4', 'active'), -- staff
  ('40000000-0000-0000-0000-0000000000a5', '10000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a5', 'active'), -- hr
  ('40000000-0000-0000-0000-0000000000a6', '10000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a6', 'active'), -- sup2
  ('40000000-0000-0000-0000-0000000000a7', '10000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a7', 'active'); -- staff2
update public.memberships set reports_to = '40000000-0000-0000-0000-0000000000a1' where id in ('40000000-0000-0000-0000-0000000000a2', '40000000-0000-0000-0000-0000000000a5');
update public.memberships set reports_to = '40000000-0000-0000-0000-0000000000a2' where id in ('40000000-0000-0000-0000-0000000000a3', '40000000-0000-0000-0000-0000000000a6');
update public.memberships set reports_to = '40000000-0000-0000-0000-0000000000a3' where id = '40000000-0000-0000-0000-0000000000a4';
update public.memberships set reports_to = '40000000-0000-0000-0000-0000000000a6' where id = '40000000-0000-0000-0000-0000000000a7';
insert into public.membership_roles (membership_id, role_id)
select m.id, r.id from (values
  ('40000000-0000-0000-0000-0000000000a1'::uuid, 'executive'), ('40000000-0000-0000-0000-0000000000a2'::uuid, 'manager'),
  ('40000000-0000-0000-0000-0000000000a3'::uuid, 'supervisor'), ('40000000-0000-0000-0000-0000000000a4'::uuid, 'staff'),
  ('40000000-0000-0000-0000-0000000000a5'::uuid, 'hr'), ('40000000-0000-0000-0000-0000000000a6'::uuid, 'supervisor'),
  ('40000000-0000-0000-0000-0000000000a7'::uuid, 'staff')
) as m (id, key) join public.roles r on r.organization_id is null and r.key = m.key;

do $$ begin
  update public.memberships set reports_to = '40000000-0000-0000-0000-0000000000a4' where id = '40000000-0000-0000-0000-0000000000a1';
  perform pg_temp.expect(false, 'reporting cycles are rejected');
exception when check_violation then perform pg_temp.expect(true, 'reporting cycles are rejected');
end $$;

do $$ begin
  perform pg_temp.expect(
    app.manager_chain('10000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a4')
      = array['00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a1']::uuid[],
    'manager chain is nearest-first');
end $$;

-- ---------------------------------------------------------------- scope via reporting line
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a7');
select public.record_attendance_event('10000000-0000-0000-0000-0000000000f1', 'clock_in', 'staff2-key-01');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select public.record_attendance_event('10000000-0000-0000-0000-0000000000f1', 'clock_in', 'staff-key-001');
reset role;

-- Everyone in one department: department scope must still not look upward.
update public.memberships set department_id = null;
insert into public.departments (id, organization_id, name) values ('20000000-0000-0000-0000-0000000000f1', '10000000-0000-0000-0000-0000000000f1', 'Ops');
update public.memberships set department_id = '20000000-0000-0000-0000-0000000000f1' where organization_id = '10000000-0000-0000-0000-0000000000f1';
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a1');
select public.record_attendance_event('10000000-0000-0000-0000-0000000000f1', 'clock_in', 'vp-key-00001');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2');
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events where user_id = '00000000-0000-0000-0000-0000000000a1') = 0,
    'department scope never exposes your own manager');
end $$;
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events where user_id = '00000000-0000-0000-0000-0000000000a7') = 1,
    'supervisor sees a direct report without a shared team');
  perform pg_temp.expect((select count(*) from public.attendance_events where user_id = '00000000-0000-0000-0000-0000000000a4') = 0,
    'supervisor cannot see another supervisor''s report');
end $$;
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2');
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events where user_id <> '00000000-0000-0000-0000-0000000000a1') = 2, 'manager sees indirect reports across both teams');
end $$;
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a1');
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events where user_id <> auth.uid()) = 0, 'executive gets no person-level attendance by default');
end $$;
reset role;

-- ---------------------------------------------------------------- routing & decisions
create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
insert into ids select 'leave1', (public.submit_request('10000000-0000-0000-0000-0000000000f1', 'leave', '{"start":"2026-12-01","end":"2026-12-03"}')).id;
insert into ids select 'ot1', (public.submit_request('10000000-0000-0000-0000-0000000000f1', 'overtime', '{"date":"2026-11-20","minutes":90}')).id;
do $$ begin
  perform pg_temp.expect(
    (select array_agg(level::text || ':' || status::text order by position) from public.approval_steps where request_id = (select id from ids where name = 'leave1'))
      = array['supervisor:pending', 'manager:waiting'], 'staff request routes supervisor → manager');
  begin
    perform public.decide_request((select id from ids where name = 'leave1'), 'approve');
    perform pg_temp.expect(false, 'requester cannot approve own request');
  exception when insufficient_privilege then perform pg_temp.expect(sqlerrm like 'self_approval%', 'requester cannot approve own request');
  end;
end $$;
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a5');
do $$ begin
  perform pg_temp.expect((select count(*) from public.approval_requests where kind = 'leave') = 1, 'HR can view leave requests org-wide');
  begin
    perform public.decide_request((select id from ids where name = 'leave1'), 'approve');
    perform pg_temp.expect(false, 'HR is not in the approval chain');
  exception when insufficient_privilege then perform pg_temp.expect(sqlerrm = 'not_approver', 'HR is not in the approval chain');
  end;
end $$;
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
do $$ begin
  perform pg_temp.expect((select count(*) from public.approval_requests) = 0, 'other supervisor cannot see the request');
end $$;
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
do $$ begin
  begin
    perform public.decide_request((select id from ids where name = 'leave1'), 'return', '   ');
    perform pg_temp.expect(false, 'return requires a reason');
  exception when sqlstate 'P0001' then perform pg_temp.expect(sqlerrm = 'reason_required', 'return requires a reason');
  end;
  perform public.decide_request((select id from ids where name = 'leave1'), 'approve');
  perform pg_temp.expect((select status from public.approval_requests where id = (select id from ids where name = 'leave1')) = 'pending',
    'supervisor endorsement keeps the request pending');
end $$;
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2');
do $$ begin
  perform public.decide_request((select id from ids where name = 'leave1'), 'approve');
  perform pg_temp.expect((select status from public.approval_requests where id = (select id from ids where name = 'leave1')) = 'approved',
    'manager gives the final approval');
  perform public.decide_request((select id from ids where name = 'ot1'), 'approve');
  perform pg_temp.expect(
    (select array_agg(status::text order by position) from public.approval_steps where request_id = (select id from ids where name = 'ot1'))
      = array['skipped', 'approved'], 'manager can approve at any stage (review skipped)');
  begin
    perform public.decide_request((select id from ids where name = 'ot1'), 'approve');
    perform pg_temp.expect(false, 'decided requests are closed');
  exception when sqlstate 'P0001' then perform pg_temp.expect(sqlerrm like 'closed%', 'decided requests are closed');
  end;
  insert into ids select 'mgr_leave', (public.submit_request('10000000-0000-0000-0000-0000000000f1', 'day_off', '{}')).id;
  perform pg_temp.expect(
    (select array_agg(approver_id) from public.approval_steps where request_id = (select id from ids where name = 'mgr_leave'))
      = array['00000000-0000-0000-0000-0000000000a1']::uuid[], 'manager''s own request goes to the executive');
end $$;
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
insert into ids select 'sup_leave', (public.submit_request('10000000-0000-0000-0000-0000000000f1', 'leave', '{}')).id;
do $$ begin
  perform pg_temp.expect(
    (select array_agg(level::text || ':' || approver_id::text) from public.approval_steps where request_id = (select id from ids where name = 'sup_leave'))
      = array['manager:00000000-0000-0000-0000-0000000000a2'], 'supervisor''s own request goes straight to the manager');
  begin
    insert into public.approval_requests (organization_id, requester_id, kind) values ('10000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a3', 'leave');
    perform pg_temp.expect(false, 'requests can only be created through submit_request');
  exception when insufficient_privilege then perform pg_temp.expect(true, 'requests can only be created through submit_request');
  end;
end $$;
reset role;

do $$ begin
  perform pg_temp.expect((select count(*) from public.audit_events where action like 'request.%') >= 6, 'every submission and decision is audited');
end $$;

rollback;
