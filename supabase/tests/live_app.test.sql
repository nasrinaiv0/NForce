-- Live app backend: sign-up → workspace → members, schedules, tasks,
-- directory and corrections.
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

-- Sign-ups (Supabase Auth inserts into auth.users).
insert into auth.users (id, email, raw_user_meta_data) values
  ('e0000000-0000-0000-0000-000000000001', 'ana@example.com', '{"full_name":"Ana Reyes"}'),
  ('e0000000-0000-0000-0000-000000000002', 'ben@example.com', '{}'),
  ('e0000000-0000-0000-0000-000000000003', 'cy@example.com', '{"full_name":"Cy Tan"}'),
  ('e0000000-0000-0000-0000-000000000004', 'dee@example.com', '{"full_name":"Dee Lim"}');
create function pg_temp.u(n integer) returns uuid language sql as $$ select ('e0000000-0000-0000-0000-00000000000' || n)::uuid $$;
create temp table ctx (k text primary key, v uuid);
grant select, insert on ctx to authenticated;
create function pg_temp.c(k text) returns uuid language sql as $$ select v from ctx where ctx.k = c.k $$;

do $$ begin
  perform pg_temp.expect((select display_name from public.profiles where id = pg_temp.u(1)) = 'Ana Reyes', 'sign-up creates a profile from the full name');
  perform pg_temp.expect((select display_name from public.profiles where id = pg_temp.u(2)) = 'ben', 'without a name, the email prefix is used');
end $$;

-- ---------------------------------------------------------------- create a workspace
select pg_temp.act_as(pg_temp.u(1));
insert into ctx select 'org', public.create_organization('Bayside Logistics', 'Asia/Manila', 'Founder');
do $$ begin
  perform pg_temp.expect(app.has_role(pg_temp.c('org'), pg_temp.u(1), array['owner']), 'the creator becomes the owner');
  perform pg_temp.expect((select count(*) from public.my_workspaces()) = 1, 'my_workspaces lists the new workspace');
  perform pg_temp.expect((select role_key from public.my_workspaces()) = 'owner', 'with the owner role');
  perform pg_temp.expect((select count(*) from public.leave_types where organization_id = pg_temp.c('org')) = 3, 'default leave types are created');
  perform pg_temp.expect((select available_days from public.leave_balances where user_id = pg_temp.u(1) and leave_type = 'vacation') = 15, 'the owner gets annual leave balances');
  perform pg_temp.expect((select count(*) from public.holidays where organization_id = pg_temp.c('org')) >= 20, 'Philippine holidays are seeded for two years');
  perform pg_temp.expect((select job_title from public.org_directory(pg_temp.c('org')) where user_id = pg_temp.u(1)) = 'Founder', 'the directory shows the job title');
end $$;
select pg_temp.raises($$ select public.create_organization('x') $$, '22023', 'organization names need at least 2 characters');
reset role;
select pg_temp.act_as(null);
select pg_temp.raises($$ select public.create_organization('Nobody Inc') $$, '28000', 'anonymous callers cannot create workspaces');
reset role;

-- ---------------------------------------------------------------- add members by email
select pg_temp.act_as(pg_temp.u(1));
do $$ begin
  insert into ctx select 'ben_m', (public.add_member_by_email(pg_temp.c('org'), 'BEN@example.com ', 'manager', pg_temp.u(1), null, 'Operations Manager')).id;
  insert into ctx select 'cy_m', (public.add_member_by_email(pg_temp.c('org'), 'cy@example.com', 'hr', pg_temp.u(1), null, 'HR Lead')).id;
  perform pg_temp.expect((select count(*) from public.org_directory(pg_temp.c('org'))) = 3, 'members are added by email (case-insensitive)');
  perform pg_temp.expect((select reports_to_user from public.org_directory(pg_temp.c('org')) where user_id = pg_temp.u(2)) = pg_temp.u(1), 'with their reporting line');
  perform pg_temp.expect((select available_days from public.leave_balances where user_id = pg_temp.u(2) and leave_type = 'sick') = 7, 'new members get leave balances');
end $$;
select pg_temp.raises($$ select public.add_member_by_email(pg_temp.c('org'), 'nobody@example.com', 'staff', pg_temp.u(1)) $$, 'P0002', 'unknown emails are refused with a clear reason');
select pg_temp.raises($$ select public.add_member_by_email(pg_temp.c('org'), 'ben@example.com', 'staff', pg_temp.u(1)) $$, 'P0001', 'existing members cannot be added twice');
reset role;
select pg_temp.act_as(pg_temp.u(3));
select pg_temp.raises($$ select public.add_member_by_email(pg_temp.c('org'), 'dee@example.com', 'payroll', pg_temp.u(3)) $$, '42501', 'HR cannot add someone with payroll access (no escalation)');
do $$ begin
  insert into ctx select 'dee_m', (public.add_member_by_email(pg_temp.c('org'), 'dee@example.com', 'staff', pg_temp.u(2), null, 'Dispatcher')).id;
  perform pg_temp.expect(true, 'HR adds staff');
end $$;
do $$ begin
  perform public.update_member_details(pg_temp.c('ben_m'), 'Head of Operations', 'Makati HQ');
  perform pg_temp.expect((select location from public.org_directory(pg_temp.c('org')) where user_id = pg_temp.u(2)) = 'Makati HQ', 'HR updates job title and location');
end $$;
select pg_temp.raises($$ select public.update_member_details((select id from public.memberships where user_id = pg_temp.u(1)), 'CEO') $$, '42501', 'HR cannot edit the owner');
select pg_temp.raises($$ select public.update_member_details(pg_temp.c('cy_m'), 'Chief People Officer') $$, '42501', 'nobody edits their own record');
reset role;

-- ---------------------------------------------------------------- schedules
select pg_temp.act_as(pg_temp.u(2));
do $$ begin
  perform public.set_member_schedule(pg_temp.c('dee_m'), '22:00', '07:00', '{6,7}');
  perform pg_temp.expect((select shift_start from public.org_directory(pg_temp.c('org')) where user_id = pg_temp.u(4)) = '22:00', 'a manager sets a report''s schedule (night shift)');
end $$;
select pg_temp.raises($$ select public.set_member_schedule(pg_temp.c('cy_m'), '08:00', '17:00', '{6,7}') $$, '42501', 'a manager cannot set schedules outside their scope');
select pg_temp.raises($$ select public.set_member_schedule(pg_temp.c('dee_m'), '08:00', '08:00', '{}') $$, '22023', 'a shift needs a length');
reset role;

-- ---------------------------------------------------------------- work items
select pg_temp.act_as(pg_temp.u(4));
do $$ begin
  insert into ctx select 'task', (public.create_work_item(pg_temp.c('org'), 'Load truck 12', 'high', current_date)).id;
  perform public.set_work_item_status(pg_temp.c('task'), 'done');
  perform pg_temp.expect((select status from public.work_items where id = pg_temp.c('task')) = 'done', 'staff create and complete their own tasks');
end $$;
select pg_temp.raises($$ select public.create_work_item(pg_temp.c('org'), 'Do my work', 'normal', null, pg_temp.u(2)) $$, '42501', 'staff cannot assign tasks to others');
reset role;
select pg_temp.act_as(pg_temp.u(2));
do $$ begin
  perform public.create_work_item(pg_temp.c('org'), 'Check dock schedule', 'normal', null, pg_temp.u(4));
  perform pg_temp.expect((select count(*) from public.work_items) = 2, 'a manager assigns and sees their report''s tasks');
end $$;
reset role;
select pg_temp.act_as(pg_temp.u(3));
do $$ begin
  perform pg_temp.expect((select count(*) from public.work_items) = 0, 'HR does not see other people''s tasks');
end $$;
reset role;

-- ---------------------------------------------------------------- directory visibility
select pg_temp.act_as('e0000000-0000-0000-0000-0000000000ff');
do $$ begin
  perform pg_temp.expect((select count(*) from public.org_directory(pg_temp.c('org'))) = 0, 'non-members see nobody');
  perform pg_temp.expect((select count(*) from public.my_workspaces()) = 0, 'and have no workspaces');
end $$;
reset role;

-- ---------------------------------------------------------------- approved corrections write the event
select pg_temp.act_as(pg_temp.u(4));
insert into ctx select 'fix', (public.submit_request(pg_temp.c('org'), 'correction',
  jsonb_build_object('date', '2026-11-20', 'requestedAt', '2026-11-21T07:04:00+08:00', 'note', 'Forgot to clock out'))).id;
reset role;
select pg_temp.act_as(pg_temp.u(2));
do $$ begin
  perform public.decide_request(pg_temp.c('fix'), 'approve');
  perform pg_temp.expect(exists (
    select 1 from public.attendance_events
    where user_id = pg_temp.u(4) and source = 'correction' and type = 'clock_out' and occurred_at = '2026-11-21T07:04:00+08:00'
  ), 'an approved correction writes the corrected clock-out');
end $$;
reset role;

rollback;
