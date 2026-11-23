-- Foundation security tests: tenant isolation, scope-aware RLS, idempotent and
-- validated clocking, immutability and same-tenant integrity.
-- Run with scripts/test-db.sh (plain Postgres) or adapt for `supabase test db`.
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

-- ---------------------------------------------------------------- fixtures
insert into auth.users (id) values
  ('00000000-0000-0000-0000-00000000000a'), -- alice: staff, team A
  ('00000000-0000-0000-0000-00000000000b'), -- bob: supervisor, team A
  ('00000000-0000-0000-0000-00000000000c'), -- cara: staff, team B (same department)
  ('00000000-0000-0000-0000-00000000000e'); -- eve: admin of another organization

insert into public.organizations (id, name, time_zone) values
  ('10000000-0000-0000-0000-000000000001', 'Acme', 'Asia/Manila'),
  ('10000000-0000-0000-0000-000000000002', 'Globex', 'America/New_York');
insert into public.departments (id, organization_id, name) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Operations');
insert into public.teams (id, organization_id, department_id, name) values
  ('30000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'Team A'),
  ('30000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'Team B');
insert into public.memberships (id, organization_id, user_id, status, department_id) values
  ('40000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'active', '20000000-0000-0000-0000-000000000001'),
  ('40000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b', 'active', '20000000-0000-0000-0000-000000000001'),
  ('40000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000c', 'active', '20000000-0000-0000-0000-000000000001'),
  ('40000000-0000-0000-0000-00000000000e', '10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000e', 'active', null);
insert into public.team_members (organization_id, team_id, membership_id) values
  ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-00000000000a'),
  ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-00000000000b'),
  ('10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-00000000000b', '40000000-0000-0000-0000-00000000000c');
insert into public.membership_roles (membership_id, role_id)
select m.id, r.id from (values
  ('40000000-0000-0000-0000-00000000000a'::uuid, 'staff'),
  ('40000000-0000-0000-0000-00000000000b'::uuid, 'supervisor'),
  ('40000000-0000-0000-0000-00000000000c'::uuid, 'staff'),
  ('40000000-0000-0000-0000-00000000000e'::uuid, 'org_admin')
) as m (id, role_key) join public.roles r on r.organization_id is null and r.key = m.role_key;

-- ---------------------------------------------------------------- integrity
do $$ begin
  begin
    insert into public.organizations (name, time_zone) values ('Bad', 'Mars/Olympus');
    perform pg_temp.expect(false, 'invalid time zone rejected');
  exception when sqlstate '22023' then perform pg_temp.expect(true, 'invalid time zone rejected');
  end;
  begin
    insert into public.team_members (organization_id, team_id, membership_id)
    values ('10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-00000000000e');
    perform pg_temp.expect(false, 'cross-tenant team membership rejected');
  exception when foreign_key_violation then perform pg_temp.expect(true, 'cross-tenant team membership rejected');
  end;
end $$;

insert into public.roles (id, organization_id, key, name)
values ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'acme_lead', 'Acme lead');
do $$ begin
  insert into public.membership_roles (membership_id, role_id)
  values ('40000000-0000-0000-0000-00000000000e', '50000000-0000-0000-0000-000000000001');
  perform pg_temp.expect(false, 'role from another tenant rejected');
exception when insufficient_privilege then perform pg_temp.expect(true, 'role from another tenant rejected');
end $$;

-- ---------------------------------------------------------------- clocking
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
do $$
declare first_id uuid; retry_id uuid;
begin
  first_id := (public.record_attendance_event('10000000-0000-0000-0000-000000000001', 'clock_in', 'alice-key-0001')).id;
  retry_id := (public.record_attendance_event('10000000-0000-0000-0000-000000000001', 'clock_in', 'alice-key-0001')).id;
  perform pg_temp.expect(first_id = retry_id, 'retried clock-in returns the original event');
  perform pg_temp.expect((select count(*) from public.attendance_events) = 1, 'retry did not create a duplicate');
  begin
    perform public.record_attendance_event('10000000-0000-0000-0000-000000000001', 'break_end', 'alice-key-0002');
    perform pg_temp.expect(false, 'invalid transition rejected');
  exception when sqlstate 'P0001' then perform pg_temp.expect(sqlerrm like 'invalid_transition%', 'invalid transition rejected');
  end;
  perform public.record_attendance_event('10000000-0000-0000-0000-000000000001', 'break_start', 'alice-key-0003');
  perform pg_temp.expect((select count(*) from public.attendance_events) = 2, 'valid transition recorded');
  begin
    perform public.record_attendance_event('10000000-0000-0000-0000-000000000001', 'clock_out', 'alice-key-0004', 'correction');
    perform pg_temp.expect(false, 'corrections cannot use the clock RPC');
  exception when insufficient_privilege then perform pg_temp.expect(true, 'corrections cannot use the clock RPC');
  end;
  begin
    insert into public.attendance_events (organization_id, user_id, type, source, idempotency_key)
    values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'clock_out', 'mobile', 'alice-direct-01');
    perform pg_temp.expect(false, 'direct inserts are denied');
  exception when insufficient_privilege then perform pg_temp.expect(true, 'direct inserts are denied');
  end;
  perform pg_temp.expect((select count(*) from public.organizations) = 1, 'alice sees only her organization');
end $$;
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-00000000000c');
select public.record_attendance_event('10000000-0000-0000-0000-000000000001', 'clock_in', 'cara-key-0001');
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events) = 1, 'cara sees only her own events');
end $$;
reset role;

-- ---------------------------------------------------------------- scoped reads
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
do $$ begin
  perform pg_temp.expect(
    (select count(*) from public.attendance_events where user_id = '00000000-0000-0000-0000-00000000000a') = 2,
    'supervisor sees own team member events');
  perform pg_temp.expect(
    (select count(*) from public.attendance_events where user_id = '00000000-0000-0000-0000-00000000000c') = 0,
    'supervisor cannot see another team (team scope only)');
end $$;
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-00000000000e');
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events) = 0, 'other tenant admin sees no attendance');
  perform pg_temp.expect((select count(*) from public.memberships where organization_id = '10000000-0000-0000-0000-000000000001') = 0,
    'other tenant admin sees no memberships');
  begin
    perform public.record_attendance_event('10000000-0000-0000-0000-000000000001', 'clock_in', 'eve-key-00001');
    perform pg_temp.expect(false, 'cannot clock into another tenant');
  exception when insufficient_privilege then perform pg_temp.expect(true, 'cannot clock into another tenant');
  end;
end $$;
reset role;

-- ---------------------------------------------------------------- delegation windows
insert into public.delegations (organization_id, membership_id, permission, scope, starts_at, expires_at, reason, created_by) values
  ('10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-00000000000a', 'attendance.view', 'department',
   now() - interval '2 days', now() - interval '1 day', 'expired cover', '00000000-0000-0000-0000-00000000000b');
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events where user_id = '00000000-0000-0000-0000-00000000000c') = 0,
    'expired delegation grants nothing');
end $$;
reset role;
insert into public.delegations (organization_id, membership_id, permission, scope, starts_at, expires_at, reason, created_by) values
  ('10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-00000000000a', 'attendance.view', 'department',
   now() - interval '1 hour', now() + interval '1 day', 'covering for Bob', '00000000-0000-0000-0000-00000000000b');
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
do $$ begin
  perform pg_temp.expect((select count(*) from public.attendance_events where user_id = '00000000-0000-0000-0000-00000000000c') = 1,
    'active delegation widens scope temporarily');
end $$;
reset role;

-- ---------------------------------------------------------------- immutability
do $$ begin
  begin
    update public.attendance_events set type = 'clock_out';
    perform pg_temp.expect(false, 'attendance events are immutable (even for owners)');
  exception when insufficient_privilege then perform pg_temp.expect(true, 'attendance events are immutable (even for owners)');
  end;
  begin
    delete from public.attendance_events;
    perform pg_temp.expect(false, 'attendance events cannot be deleted');
  exception when insufficient_privilege then perform pg_temp.expect(true, 'attendance events cannot be deleted');
  end;
end $$;

-- ---------------------------------------------------------------- anonymous
set local role anon;
do $$ begin
  begin
    perform count(*) from public.organizations;
    perform pg_temp.expect(false, 'anonymous users have no table access');
  exception when insufficient_privilege then perform pg_temp.expect(true, 'anonymous users have no table access');
  end;
end $$;
reset role;

rollback;
