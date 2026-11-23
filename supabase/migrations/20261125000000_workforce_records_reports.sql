-- =============================================================================
-- NForce · Phase 3: timesheets, leave ledger, payroll periods, notifications,
-- CRM and aggregate executive reporting.
--
-- * Timesheets move through submit_timesheet() and the hierarchical approval
--   chain; a trigger applies the final decision. Locked rows are immutable.
-- * Leave balances are an append-only ledger; approved leave posts usage.
-- * lock_payroll_period() refuses while any timesheet is not approved.
-- * Notifications are written by triggers (approver on a pending step,
--   requester on a decision) and are readable only by their recipient.
-- * report_attendance_summary() returns aggregates only, folding groups
--   smaller than 3 people into "Other" so no individual can be singled out.
-- =============================================================================

create type public.timesheet_status as enum ('draft', 'submitted', 'returned', 'approved', 'locked');
create type public.leave_txn_kind as enum ('accrual', 'usage', 'adjustment');
create type public.deal_stage as enum ('lead', 'qualified', 'proposal', 'negotiation', 'won', 'lost');

-- ---------------------------------------------------------------------------
-- Timesheets
-- ---------------------------------------------------------------------------
create table public.timesheets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  user_id uuid not null,
  period_start date not null check (extract(isodow from period_start) = 1),
  status public.timesheet_status not null default 'draft',
  worked_minutes integer not null default 0 check (worked_minutes >= 0),
  overtime_minutes integer not null default 0 check (overtime_minutes >= 0),
  version integer not null default 1,
  submitted_at timestamptz,
  decided_at timestamptz,
  locked_at timestamptz,
  unique (organization_id, user_id, period_start),
  foreign key (organization_id, user_id) references public.memberships (organization_id, user_id)
);

create function app.protect_locked_timesheet() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'timesheets cannot be deleted' using errcode = '42501';
  end if;
  if old.status = 'locked' then
    raise exception 'locked timesheets are immutable; use an audited adjustment' using errcode = '42501';
  end if;
  new.version := old.version + 1;
  return new;
end $$;
create trigger timesheets_protect before update or delete on public.timesheets
  for each row execute function app.protect_locked_timesheet();

create function public.submit_timesheet(p_organization_id uuid, p_period_start date, p_worked_minutes integer default 0, p_overtime_minutes integer default 0)
returns public.timesheets
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_sheet public.timesheets;
begin
  if v_user is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not app.has_permission(p_organization_id, 'timesheet.submit', v_user) then raise exception 'forbidden' using errcode = '42501'; end if;

  insert into public.timesheets (organization_id, user_id, period_start)
  values (p_organization_id, v_user, p_period_start)
  on conflict (organization_id, user_id, period_start) do nothing;
  select * into v_sheet from public.timesheets
  where organization_id = p_organization_id and user_id = v_user and period_start = p_period_start for update;
  if v_sheet.status not in ('draft', 'returned') then
    raise exception 'invalid_transition: cannot submit a % timesheet', v_sheet.status using errcode = 'P0001';
  end if;

  update public.timesheets
  set status = 'submitted', worked_minutes = greatest(0, p_worked_minutes), overtime_minutes = greatest(0, p_overtime_minutes), submitted_at = now()
  where id = v_sheet.id returning * into v_sheet;
  perform public.submit_request(p_organization_id, 'timesheet',
    jsonb_build_object('periodStart', p_period_start, 'minutes', p_worked_minutes, 'overtimeMinutes', p_overtime_minutes));
  return v_sheet;
end $$;

-- ---------------------------------------------------------------------------
-- Leave ledger (append-only)
-- ---------------------------------------------------------------------------
create table public.leave_types (
  organization_id uuid not null references public.organizations (id) on delete cascade,
  key text not null check (key ~ '^[a-z_]+$'),
  name text not null,
  allow_half_days boolean not null default false,
  min_notice_days integer not null default 0 check (min_notice_days >= 0),
  max_consecutive_days integer not null default 15 check (max_consecutive_days > 0),
  primary key (organization_id, key)
);

create table public.leave_transactions (
  id bigint generated always as identity primary key,
  organization_id uuid not null,
  user_id uuid not null,
  leave_type text not null,
  kind public.leave_txn_kind not null,
  days numeric(6, 2) not null check (days <> 0),
  request_id uuid references public.approval_requests (id),
  note text,
  created_at timestamptz not null default now(),
  foreign key (organization_id, user_id) references public.memberships (organization_id, user_id),
  foreign key (organization_id, leave_type) references public.leave_types (organization_id, key),
  unique (request_id)
);
create trigger leave_transactions_immutable before update or delete on public.leave_transactions
  for each row execute function app.forbid_mutation();

create view public.leave_balances with (security_invoker = true) as
  select organization_id, user_id, leave_type, sum(days) as available_days,
         sum(days) filter (where kind = 'accrual') as entitled_days
  from public.leave_transactions
  group by organization_id, user_id, leave_type;

-- ---------------------------------------------------------------------------
-- Payroll periods
-- ---------------------------------------------------------------------------
create table public.payroll_periods (
  organization_id uuid not null references public.organizations (id) on delete cascade,
  period_start date not null,
  locked_by uuid not null references auth.users (id),
  locked_at timestamptz not null default now(),
  primary key (organization_id, period_start)
);
create trigger payroll_periods_immutable before update or delete on public.payroll_periods
  for each row execute function app.forbid_mutation();

create function public.lock_payroll_period(p_organization_id uuid, p_period_start date)
returns public.payroll_periods
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_blockers integer;
  v_period public.payroll_periods;
begin
  if v_user is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not app.has_permission(p_organization_id, 'payroll.prepare') then raise exception 'forbidden' using errcode = '42501'; end if;
  if exists (select 1 from public.payroll_periods where organization_id = p_organization_id and period_start = p_period_start) then
    raise exception 'closed: period already locked' using errcode = 'P0001';
  end if;
  select count(*) into v_blockers from public.timesheets
  where organization_id = p_organization_id and period_start = p_period_start and status not in ('approved', 'locked');
  if v_blockers > 0 then
    raise exception 'not_ready: % timesheet(s) not approved', v_blockers using errcode = 'P0001';
  end if;
  update public.timesheets set status = 'locked', locked_at = now()
  where organization_id = p_organization_id and period_start = p_period_start and status = 'approved';
  insert into public.payroll_periods (organization_id, period_start, locked_by)
  values (p_organization_id, p_period_start, v_user) returning * into v_period;
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (p_organization_id, v_user, 'payroll.locked', 'payroll_period', p_period_start::text, '{}'::jsonb);
  return v_period;
end $$;

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  user_id uuid not null,
  kind text not null,
  params jsonb not null default '{}'::jsonb,
  href text,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  foreign key (organization_id, user_id) references public.memberships (organization_id, user_id) on delete cascade
);
create index notifications_inbox_idx on public.notifications (user_id, created_at desc);

create function public.mark_notifications_read(p_ids uuid[]) returns integer
language sql security definer set search_path = '' as $$
  with u as (
    update public.notifications set read_at = now()
    where id = any (p_ids) and user_id = auth.uid() and read_at is null
    returning 1
  )
  select count(*)::integer from u
$$;

-- Workflow side effects: apply final decisions and notify people.
create function app.on_request_decided() returns trigger
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
  end if;
  insert into public.notifications (organization_id, user_id, kind, params, href)
  values (new.organization_id, new.requester_id, 'request_decided',
          jsonb_build_object('kind', new.kind, 'status', new.status, 'requestId', new.id), '/more/timeoff');
  return new;
end $$;
create trigger approval_requests_decided after update of status on public.approval_requests
  for each row when (old.status = 'pending' and new.status in ('approved', 'returned'))
  execute function app.on_request_decided();

create function app.on_step_pending() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (organization_id, user_id, kind, params, href)
  select new.organization_id, new.approver_id, 'approval_needed',
         jsonb_build_object('requestId', new.request_id, 'kind', r.kind, 'level', new.level), '/more/approvals'
  from public.approval_requests r where r.id = new.request_id;
  return new;
end $$;
create trigger approval_steps_pending after insert or update of status on public.approval_steps
  for each row when (new.status = 'pending') execute function app.on_step_pending();

-- ---------------------------------------------------------------------------
-- CRM
-- ---------------------------------------------------------------------------
create table public.crm_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 200),
  unique (organization_id, id)
);
create table public.crm_deals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  account_id uuid not null,
  name text not null check (length(btrim(name)) between 1 and 200),
  stage public.deal_stage not null default 'lead',
  amount_minor bigint not null check (amount_minor >= 0),
  currency char(3) not null default 'PHP',
  owner_id uuid,
  close_date date,
  lost_reason text,
  foreign key (organization_id, account_id) references public.crm_accounts (organization_id, id) on delete cascade
);

create function public.move_deal(p_deal_id uuid, p_stage public.deal_stage, p_reason text default null)
returns public.crm_deals
language plpgsql security definer set search_path = '' as $$
declare v_deal public.crm_deals;
begin
  select * into v_deal from public.crm_deals where id = p_deal_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if not app.has_permission(v_deal.organization_id, 'crm.manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if v_deal.stage in ('won', 'lost') then raise exception 'closed_deal' using errcode = 'P0001'; end if;
  if p_stage = 'lost' and nullif(btrim(p_reason), '') is null then raise exception 'reason_required' using errcode = 'P0001'; end if;
  update public.crm_deals set stage = p_stage, lost_reason = case when p_stage = 'lost' then btrim(p_reason) end
  where id = p_deal_id returning * into v_deal;
  insert into public.audit_events (organization_id, actor_id, action, entity, entity_id, data)
  values (v_deal.organization_id, auth.uid(), 'crm.deal_moved', 'crm_deal', p_deal_id::text, jsonb_build_object('stage', p_stage));
  return v_deal;
end $$;

-- ---------------------------------------------------------------------------
-- Aggregate executive reporting (no person-level output)
-- ---------------------------------------------------------------------------
create function public.report_attendance_summary(p_organization_id uuid, p_from date, p_to date)
returns table (group_name text, headcount integer, present_person_days integer, avg_first_clock_in_minutes integer)
language plpgsql stable security definer set search_path = '' as $$
declare v_tz text;
begin
  if not app.has_permission(p_organization_id, 'reports.organization') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_to < p_from or p_to - p_from > 366 then
    raise exception 'invalid range' using errcode = '22023';
  end if;
  select o.time_zone into v_tz from public.organizations o where o.id = p_organization_id;
  return query
  with members as (
    select m.user_id, coalesce(d.name, 'Unassigned') as dept
    from public.memberships m left join public.departments d on d.id = m.department_id
    where m.organization_id = p_organization_id and m.status = 'active'
  ),
  sizes as (select dept, count(*) as n from members group by dept),
  labeled as (
    select mb.user_id, case when s.n >= 3 then mb.dept else 'Other' end as grp
    from members mb join sizes s using (dept)
  ),
  firsts as (
    select e.user_id, (e.occurred_at at time zone v_tz)::date as d, min(e.occurred_at at time zone v_tz) as first_in
    from public.attendance_events e
    where e.organization_id = p_organization_id and e.type = 'clock_in'
      and (e.occurred_at at time zone v_tz)::date between p_from and p_to
    group by 1, 2
  )
  select l.grp, count(distinct l.user_id)::integer, count(f.user_id)::integer,
         round(avg(extract(hour from f.first_in) * 60 + extract(minute from f.first_in)))::integer
  from labeled l left join firsts f on f.user_id = l.user_id
  group by l.grp
  order by l.grp;
end $$;

-- ---------------------------------------------------------------------------
-- RLS & privileges
-- ---------------------------------------------------------------------------
alter table public.timesheets enable row level security;
alter table public.leave_types enable row level security;
alter table public.leave_transactions enable row level security;
alter table public.payroll_periods enable row level security;
alter table public.notifications enable row level security;
alter table public.crm_accounts enable row level security;
alter table public.crm_deals enable row level security;

create policy timesheets_read on public.timesheets for select to authenticated
  using (app.has_permission(organization_id, 'timesheet.view', user_id));
create policy leave_types_read on public.leave_types for select to authenticated using (app.is_member(organization_id));
create policy leave_transactions_read on public.leave_transactions for select to authenticated
  using (app.has_permission(organization_id, 'timeoff.view', user_id));
create policy payroll_periods_read on public.payroll_periods for select to authenticated
  using (app.has_permission(organization_id, 'payroll.view'));
create policy notifications_read on public.notifications for select to authenticated using (user_id = auth.uid());
create policy crm_accounts_read on public.crm_accounts for select to authenticated using (app.has_permission(organization_id, 'crm.view'));
create policy crm_deals_read on public.crm_deals for select to authenticated using (app.has_permission(organization_id, 'crm.view'));

revoke all on public.timesheets, public.leave_types, public.leave_transactions, public.leave_balances, public.payroll_periods,
  public.notifications, public.crm_accounts, public.crm_deals from anon;
revoke insert, update, delete, truncate on public.timesheets, public.leave_types, public.leave_transactions, public.payroll_periods,
  public.notifications, public.crm_accounts, public.crm_deals from authenticated;
grant select on public.timesheets, public.leave_types, public.leave_transactions, public.leave_balances, public.payroll_periods,
  public.notifications, public.crm_accounts, public.crm_deals to authenticated;

revoke all on function public.submit_timesheet(uuid, date, integer, integer), public.lock_payroll_period(uuid, date),
  public.mark_notifications_read(uuid[]), public.move_deal(uuid, public.deal_stage, text),
  public.report_attendance_summary(uuid, date, date) from public;
grant execute on function public.submit_timesheet(uuid, date, integer, integer), public.lock_payroll_period(uuid, date),
  public.mark_notifications_read(uuid[]), public.move_deal(uuid, public.deal_stage, text),
  public.report_attendance_summary(uuid, date, date) to authenticated;
