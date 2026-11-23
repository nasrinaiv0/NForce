-- =============================================================================
-- NForce · Live app backend: what the app needs to run on Supabase.
--
-- * Sign-up creates a profile; create_organization() lets a new user start a
--   workspace and become its owner (leave types, holidays and balances seeded).
-- * Members carry a job title, location and a weekly work pattern (shift start
--   and end, rest days); set_member_schedule() needs schedule.manage.
-- * add_member_by_email() adds an existing NForce account to the organization
--   (people.manage, no privilege escalation; same rules as add_member()).
-- * Work items (Work Center tasks) with row-level security by work.view scope.
-- * org_directory() and my_workspaces() give the app one round trip each.
-- * Approved attendance corrections write the corrected clock-out event.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Member details and work pattern
-- ---------------------------------------------------------------------------
alter table public.memberships
  add column job_title text not null default '' check (length(job_title) <= 120),
  add column location text not null default '' check (length(location) <= 120),
  add column shift_start time not null default '09:00',
  add column shift_end time not null default '18:00',
  add column rest_days smallint[] not null default '{6,7}'
    check (rest_days <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[] and cardinality(rest_days) <= 6);

alter table public.leave_types add column annual_days numeric(5, 2) not null default 0 check (annual_days >= 0 and annual_days <= 366);

-- ---------------------------------------------------------------------------
-- Profiles are created at sign-up
-- ---------------------------------------------------------------------------
create function app.display_name_for(p_meta jsonb, p_email text) returns text
language sql immutable set search_path = '' as $$
  select left(coalesce(
    nullif(btrim(p_meta ->> 'full_name'), ''),
    nullif(btrim(p_meta ->> 'name'), ''),
    nullif(split_part(coalesce(p_email, ''), '@', 1), ''),
    'New user'), 120)
$$;

create function app.on_auth_user_created() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, app.display_name_for(new.raw_user_meta_data, new.email))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function app.on_auth_user_created();

insert into public.profiles (id, display_name)
select u.id, app.display_name_for(u.raw_user_meta_data, u.email) from auth.users u
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Leave entitlements: one accrual per leave type when someone joins
-- ---------------------------------------------------------------------------
create function app.seed_leave_balances(p_org uuid, p_user uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.leave_transactions (organization_id, user_id, leave_type, kind, days, note)
  select t.organization_id, p_user, t.key, 'accrual', t.annual_days, 'Annual entitlement'
  from public.leave_types t
  where t.organization_id = p_org and t.annual_days > 0
    and not exists (
      select 1 from public.leave_transactions x
      where x.organization_id = p_org and x.user_id = p_user and x.leave_type = t.key and x.kind = 'accrual'
    )
$$;

-- ---------------------------------------------------------------------------
-- Start a workspace: the caller becomes its owner
-- ---------------------------------------------------------------------------
create function public.create_organization(p_name text, p_time_zone text default 'Asia/Manila', p_job_title text default 'Owner')
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_org uuid;
  v_dept uuid;
  v_member uuid;
  v_year integer := extract(year from now())::integer;
begin
  if v_user is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if length(btrim(coalesce(p_name, ''))) not between 2 and 200 then
    raise exception 'invalid: organization name must be 2–200 characters' using errcode = '22023';
  end if;
  if (select count(*) from public.memberships m where m.user_id = v_user and m.status = 'active') >= 10 then
    raise exception 'limit: you already belong to 10 organizations' using errcode = 'P0001';
  end if;

  insert into public.organizations (name, time_zone) values (btrim(p_name), coalesce(nullif(p_time_zone, ''), 'UTC')) returning id into v_org;
  insert into public.departments (organization_id, name) values (v_org, 'Executive Office') returning id into v_dept;
  insert into public.memberships (organization_id, user_id, status, department_id, job_title)
  values (v_org, v_user, 'active', v_dept, left(btrim(coalesce(p_job_title, 'Owner')), 120)) returning id into v_member;
  insert into public.membership_roles (membership_id, role_id)
  select v_member, r.id from public.roles r where r.organization_id is null and r.key = 'owner';

  insert into public.leave_types (organization_id, key, name, allow_half_days, min_notice_days, max_consecutive_days, annual_days) values
    (v_org, 'vacation', 'Vacation', true, 3, 15, 15),
    (v_org, 'sick', 'Sick leave', true, 0, 10, 7),
    (v_org, 'wellness', 'Wellness day', false, 1, 1, 2);
  perform app.seed_leave_balances(v_org, v_user);

  -- Philippine fixed-date holidays for this year and next (editable later).
  if p_time_zone = 'Asia/Manila' then
    insert into public.holidays (organization_id, date, kind, name)
    select v_org, make_date(y, h.m, h.d), h.kind::public.holiday_kind, h.name
    from generate_series(v_year, v_year + 1) y
    cross join (values
      (1, 1, 'regular', 'New Year''s Day'), (4, 9, 'regular', 'Araw ng Kagitingan'), (5, 1, 'regular', 'Labor Day'),
      (6, 12, 'regular', 'Independence Day'), (11, 30, 'regular', 'Bonifacio Day'), (12, 25, 'regular', 'Christmas Day'),
      (12, 30, 'regular', 'Rizal Day'), (8, 21, 'special', 'Ninoy Aquino Day'), (11, 1, 'special', 'All Saints'' Day'),
      (12, 8, 'special', 'Feast of the Immaculate Conception'), (12, 31, 'special', 'Last Day of the Year')
    ) as h (m, d, kind, name)
    on conflict do nothing;
  end if;

  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_org, v_user, 'organization.created', 'organization', v_org::text, jsonb_build_object('name', btrim(p_name)));
  return v_org;
end $$;

-- ---------------------------------------------------------------------------
-- Add an existing NForce account by email
-- ---------------------------------------------------------------------------
create function public.add_member_by_email(
  p_organization_id uuid,
  p_email text,
  p_role_key text,
  p_reports_to_user uuid,
  p_department_id uuid default null,
  p_job_title text default ''
) returns public.memberships
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid;
  v_manager uuid;
  v_member public.memberships;
begin
  if not app.has_permission(p_organization_id, 'people.manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select u.id into v_user from auth.users u where lower(u.email) = lower(btrim(p_email)) limit 1;
  if v_user is null then
    raise exception 'user_not_found: ask them to create an NForce account with this email first' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.memberships where organization_id = p_organization_id and user_id = v_user) then
    raise exception 'already_member: this person is already in the organization' using errcode = 'P0001';
  end if;
  select id into v_manager from public.memberships
  where organization_id = p_organization_id and user_id = p_reports_to_user and status = 'active';
  if v_manager is null then raise exception 'invalid manager: choose an active member of this organization' using errcode = '22023'; end if;

  v_member := public.add_member(p_organization_id, v_user, p_role_key, v_manager, p_department_id);
  update public.memberships set job_title = left(btrim(coalesce(p_job_title, '')), 120) where id = v_member.id returning * into v_member;
  perform app.seed_leave_balances(p_organization_id, v_user);
  return v_member;
end $$;

-- Job title and location (HR / owners; never yourself, owners only by owners).
create function public.update_member_details(p_membership_id uuid, p_job_title text, p_location text default null)
returns public.memberships
language plpgsql security definer set search_path = '' as $$
declare v_target public.memberships;
begin
  select * into v_target from public.memberships where id = p_membership_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_target.status <> 'active' then raise exception 'already_inactive' using errcode = 'P0001'; end if;
  perform app.assert_can_manage(v_target, array['people.manage']);
  update public.memberships
  set job_title = left(btrim(coalesce(p_job_title, job_title)), 120), location = left(btrim(coalesce(p_location, location)), 120)
  where id = p_membership_id returning * into v_target;
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_target.organization_id, auth.uid(), 'member.updated', 'membership', p_membership_id::text, jsonb_build_object('jobTitle', v_target.job_title));
  return v_target;
end $$;

-- Weekly work pattern (schedule.manage at a scope reaching the person).
create function public.set_member_schedule(p_membership_id uuid, p_shift_start time, p_shift_end time, p_rest_days smallint[])
returns public.memberships
language plpgsql security definer set search_path = '' as $$
declare v_target public.memberships;
begin
  select * into v_target from public.memberships where id = p_membership_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if not app.has_permission(v_target.organization_id, 'schedule.manage', v_target.user_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_shift_start = p_shift_end then raise exception 'invalid: a shift needs a length' using errcode = '22023'; end if;
  update public.memberships set shift_start = p_shift_start, shift_end = p_shift_end, rest_days = coalesce(p_rest_days, rest_days)
  where id = p_membership_id returning * into v_target;
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_target.organization_id, auth.uid(), 'schedule.updated', 'membership', p_membership_id::text,
          jsonb_build_object('start', p_shift_start, 'end', p_shift_end, 'restDays', p_rest_days));
  return v_target;
end $$;

-- ---------------------------------------------------------------------------
-- Work Center tasks
-- ---------------------------------------------------------------------------
create type public.work_status as enum ('todo', 'in_progress', 'blocked', 'done');
create type public.work_priority as enum ('low', 'normal', 'high', 'urgent');

create table public.work_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  assignee_id uuid not null,
  created_by uuid not null,
  title text not null check (length(btrim(title)) between 1 and 200),
  status public.work_status not null default 'todo',
  priority public.work_priority not null default 'normal',
  due date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organization_id, assignee_id) references public.memberships (organization_id, user_id) on delete cascade
);
create index work_items_assignee_idx on public.work_items (organization_id, assignee_id, status);
alter table public.work_items enable row level security;
create policy work_items_read on public.work_items for select to authenticated
  using (app.has_permission(organization_id, 'work.view', assignee_id));
revoke all on public.work_items from anon;
revoke insert, update, delete, truncate on public.work_items from authenticated;
grant select on public.work_items to authenticated;

create function public.create_work_item(
  p_organization_id uuid, p_title text, p_priority public.work_priority default 'normal', p_due date default null, p_assignee uuid default null
) returns public.work_items
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_assignee uuid := coalesce(p_assignee, auth.uid());
  v_item public.work_items;
begin
  if v_user is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if v_assignee = v_user then
    if not app.has_permission(p_organization_id, 'work.create', v_user) then raise exception 'forbidden' using errcode = '42501'; end if;
  elsif not app.has_permission(p_organization_id, 'work.assign', v_assignee) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_title, ''))) = 0 then raise exception 'invalid: give the task a title' using errcode = '22023'; end if;
  insert into public.work_items (organization_id, assignee_id, created_by, title, priority, due)
  values (p_organization_id, v_assignee, v_user, btrim(p_title), coalesce(p_priority, 'normal'), p_due) returning * into v_item;
  return v_item;
end $$;

create function public.set_work_item_status(p_id uuid, p_status public.work_status) returns public.work_items
language plpgsql security definer set search_path = '' as $$
declare v_item public.work_items;
begin
  select * into v_item from public.work_items where id = p_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if not (
    (v_item.assignee_id = auth.uid() and app.has_permission(v_item.organization_id, 'work.view', v_item.assignee_id))
    or app.has_permission(v_item.organization_id, 'work.assign', v_item.assignee_id)
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.work_items set status = p_status, updated_at = now() where id = p_id returning * into v_item;
  return v_item;
end $$;

-- ---------------------------------------------------------------------------
-- One-round-trip reads for the app
-- ---------------------------------------------------------------------------
-- The caller's workspaces.
create function public.my_workspaces()
returns table (organization_id uuid, name text, time_zone text, membership_id uuid, role_key text)
language sql stable security definer set search_path = '' as $$
  select o.id, o.name, o.time_zone, m.id,
         (select r.key from public.membership_roles mr join public.roles r on r.id = mr.role_id where mr.membership_id = m.id order by r.key limit 1)
  from public.memberships m join public.organizations o on o.id = m.organization_id
  where m.user_id = auth.uid() and m.status = 'active'
  order by o.name
$$;

-- Everyone the caller may see in the directory (ended members included, so
-- names in history still resolve; the app hides them from lists).
create function public.org_directory(p_organization_id uuid)
returns table (
  user_id uuid, membership_id uuid, display_name text, job_title text, location text, status public.membership_status,
  department_id uuid, department_name text, team_id uuid, team_name text, reports_to_user uuid, role_key text,
  shift_start time, shift_end time, rest_days smallint[]
)
language sql stable security definer set search_path = '' as $$
  select m.user_id, m.id, coalesce(p.display_name, 'Member'), m.job_title, m.location, m.status,
         m.department_id, d.name,
         tm.team_id, t.name,
         boss.user_id,
         (select r.key from public.membership_roles mr join public.roles r on r.id = mr.role_id where mr.membership_id = m.id order by r.key limit 1),
         m.shift_start, m.shift_end, m.rest_days
  from public.memberships m
  left join public.profiles p on p.id = m.user_id
  left join public.departments d on d.id = m.department_id
  left join lateral (select x.team_id from public.team_members x where x.membership_id = m.id limit 1) tm on true
  left join public.teams t on t.id = tm.team_id
  left join public.memberships boss on boss.id = m.reports_to
  where m.organization_id = p_organization_id
    and app.is_member(p_organization_id)
    and (m.user_id = auth.uid() or app.has_permission(p_organization_id, 'people.directory', m.user_id))
$$;

-- ---------------------------------------------------------------------------
-- Approved corrections write the corrected clock-out
-- ---------------------------------------------------------------------------
create or replace function app.on_request_decided() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind = 'timesheet' then
    update public.timesheets
    set status = case when new.status = 'approved' then 'approved'::public.timesheet_status else 'returned'::public.timesheet_status end,
        decided_at = now()
    where organization_id = new.organization_id and user_id = new.requester_id
      and period_start = (new.payload ->> 'periodStart')::date and status = 'submitted';
  elsif new.kind = 'leave' and new.status = 'approved' then
    insert into public.leave_transactions (organization_id, user_id, leave_type, kind, days, request_id)
    values (new.organization_id, new.requester_id, new.payload ->> 'leaveTypeId', 'usage', -((new.payload ->> 'days')::numeric), new.id);
  elsif new.kind = 'correction' and new.status = 'approved' and new.payload ? 'requestedAt' then
    insert into public.attendance_events (organization_id, user_id, type, occurred_at, source, idempotency_key, note)
    values (new.organization_id, new.requester_id, 'clock_out', (new.payload ->> 'requestedAt')::timestamptz, 'correction',
            'correction-' || new.id::text, left(new.payload ->> 'note', 500))
    on conflict (organization_id, user_id, idempotency_key) do nothing;
  end if;
  insert into public.notifications (organization_id, user_id, kind, params, href)
  values (new.organization_id, new.requester_id, 'request_decided',
          jsonb_build_object('kind', new.kind, 'status', new.status, 'requestId', new.id), '/more/timeoff');
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
revoke all on function app.display_name_for(jsonb, text), app.on_auth_user_created(), app.seed_leave_balances(uuid, uuid) from public;
revoke all on function public.create_organization(text, text, text), public.add_member_by_email(uuid, text, text, uuid, uuid, text),
  public.update_member_details(uuid, text, text), public.set_member_schedule(uuid, time, time, smallint[]),
  public.create_work_item(uuid, text, public.work_priority, date, uuid), public.set_work_item_status(uuid, public.work_status),
  public.my_workspaces(), public.org_directory(uuid) from public;
grant execute on function public.create_organization(text, text, text), public.add_member_by_email(uuid, text, text, uuid, uuid, text),
  public.update_member_details(uuid, text, text), public.set_member_schedule(uuid, time, time, smallint[]),
  public.create_work_item(uuid, text, public.work_priority, date, uuid), public.set_work_item_status(uuid, public.work_status),
  public.my_workspaces(), public.org_directory(uuid) to authenticated;
