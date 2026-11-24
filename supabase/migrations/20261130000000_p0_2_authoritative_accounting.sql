
-- P0.2 candidate: private, server-authoritative weekly hours reconciliation.
-- No grants to API roles; P0 public RPC revocations remain in force.
create table app.accounting_period_manifest (
  organization_id uuid not null references public.organizations(id),
  period_start date not null check (extract(isodow from period_start) = 1),
  time_zone text not null,
  roster_reference text not null check (length(btrim(roster_reference)) > 0),
  attested_by uuid not null references auth.users(id),
  sealed boolean not null default false,
  primary key (organization_id, period_start)
);
create table app.accounting_roster_day (
  organization_id uuid not null,
  period_start date not null,
  user_id uuid not null,
  work_date date not null,
  regular_minutes integer not null check (regular_minutes between 1 and 960),
  minimum_ot_minutes integer not null check (minimum_ot_minutes between 0 and 960),
  policy_reference text not null check (length(btrim(policy_reference)) > 0),
  primary key (organization_id, period_start, user_id, work_date),
  foreign key (organization_id, period_start) references app.accounting_period_manifest,
  foreign key (organization_id, user_id) references public.memberships(organization_id,user_id),
  check (work_date >= period_start and work_date < period_start + 7)
);
create table app.accounting_submission (
  organization_id uuid not null,
  period_start date not null,
  user_id uuid not null,
  reconciliation jsonb not null,
  sheet_id uuid not null references public.timesheets(id),
  primary key (organization_id, period_start, user_id),
  foreign key (organization_id, period_start) references app.accounting_period_manifest,
  foreign key (organization_id,user_id) references public.memberships(organization_id,user_id)
);
create table app.accounting_request_ticket (
  organization_id uuid not null,
  user_id uuid not null,
  payload jsonb not null,
  backend_pid integer not null,
  transaction_id bigint not null,
  primary key (backend_pid,transaction_id)
);
create table app.accounting_locked_snapshot (
  organization_id uuid not null,
  period_start date not null,
  user_id uuid not null,
  reconciliation jsonb not null,
  primary key (organization_id,period_start,user_id),
  foreign key (organization_id,period_start,user_id) references app.accounting_submission
);
revoke all on app.accounting_period_manifest, app.accounting_roster_day,
  app.accounting_submission, app.accounting_request_ticket, app.accounting_locked_snapshot
from public, anon, authenticated, service_role;
alter table app.accounting_period_manifest enable row level security;
alter table app.accounting_roster_day enable row level security;
alter table app.accounting_submission enable row level security;
alter table app.accounting_request_ticket enable row level security;
alter table app.accounting_locked_snapshot enable row level security;

-- A trusted importer must explicitly attest coverage. Do not reconstruct old
-- employment or schedules from the current membership row.
create function app.accounting_guard_manifest() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'manifest immutable' using errcode='42501'; end if;
  if tg_op = 'UPDATE' and old.sealed then raise exception 'manifest sealed' using errcode='42501'; end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name=new.time_zone) then
    raise exception 'invalid historical timezone' using errcode='22023';
  end if;
  if new.sealed and not exists (select 1 from app.accounting_roster_day d
      where d.organization_id=new.organization_id and d.period_start=new.period_start) then
    raise exception 'empty historical roster' using errcode='P0001';
  end if;
  return new;
end $$;
create trigger accounting_manifest_guard before insert or update or delete on app.accounting_period_manifest
for each row execute function app.accounting_guard_manifest();

create function app.accounting_guard_roster() returns trigger
language plpgsql set search_path = '' as $$
declare v_sealed boolean;
begin
  if tg_op <> 'INSERT' then raise exception 'historical roster immutable' using errcode='42501'; end if;
  select sealed into v_sealed from app.accounting_period_manifest
  where organization_id=new.organization_id and period_start=new.period_start for update;
  if not found or v_sealed then raise exception 'manifest unavailable or sealed' using errcode='42501'; end if;
  return new;
end $$;
create trigger accounting_roster_guard before insert or update or delete on app.accounting_roster_day
for each row execute function app.accounting_guard_roster();
create trigger accounting_locked_immutable before update or delete on app.accounting_locked_snapshot
for each row execute function app.forbid_mutation();

-- Private computation. Attribution is the local clock-in day, including
-- overnight sessions. Round down each worked interval, not wall-clock time.
-- Fail closed on ambiguous sequences, long or open sessions, missing coverage,
-- pending corrections and pending OT. This is hours reconciliation, not wages.
create function app.accounting_reconcile(p_org uuid,p_period date,p_user uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  m app.accounting_period_manifest;
  e public.attendance_events;
  d app.accounting_roster_day;
  v_from timestamptz;
  v_to timestamptz;
  v_scan timestamptz;
  v_last public.attendance_event_type;
  v_state text := 'off';
  v_in timestamptz;
  v_interval timestamptz;
  v_day date;
  v_session integer := 0;
  v_minutes jsonb := '{}'::jsonb;
  v_evidence jsonb := '[]'::jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_worked integer := 0;
  v_ot integer := 0;
  v_approved integer := 0;
  v_unapproved integer := 0;
  n integer; o integer; a integer; q integer;
begin
  select * into m from app.accounting_period_manifest
  where organization_id=p_org and period_start=p_period and sealed;
  if not found then raise exception 'sealed historical roster required' using errcode='P0001'; end if;
  if not exists(select 1 from app.accounting_roster_day where organization_id=p_org and period_start=p_period and user_id=p_user) then
    raise exception 'historical employee eligibility missing' using errcode='P0001';
  end if;
  v_from := p_period::timestamp at time zone m.time_zone;
  v_to := (p_period+7)::timestamp at time zone m.time_zone;
  if now() < v_to + interval '16 hours' then raise exception 'period not closed' using errcode='P0001'; end if;
  -- Include any carry-in session and enough time to finish the final overnight.
  v_scan := v_from;
  select type into v_last from public.attendance_events
    where organization_id=p_org and user_id=p_user and occurred_at<v_from
    order by occurred_at desc,created_at desc,id desc limit 1;
  if v_last is not null and v_last <> 'clock_out' then
    select max(occurred_at) into v_scan from public.attendance_events
      where organization_id=p_org and user_id=p_user and occurred_at<v_from and type='clock_in';
    if v_scan is null or v_scan < v_from-interval '16 hours' then
      raise exception 'unresolved carry-in punch' using errcode='P0001';
    end if;
  end if;
  for e in select * from public.attendance_events
    where organization_id=p_org and user_id=p_user and occurred_at>=v_scan
      and occurred_at<=v_to+interval '16 hours'
    order by occurred_at,created_at,id
  loop
    if v_state='off' and e.occurred_at>=v_to then exit; end if;
    v_evidence := v_evidence || jsonb_build_array(jsonb_build_object('id',e.id,'type',e.type,'at',e.occurred_at));
    if e.type='clock_in' and v_state='off' then
      v_state:='working'; v_in:=e.occurred_at; v_interval:=v_in; v_session:=0;
    elsif e.type='break_start' and v_state='working' then
      v_session:=v_session+floor(extract(epoch from e.occurred_at-v_interval)/60)::integer;
      v_state:='break';
    elsif e.type='break_end' and v_state='break' then
      v_state:='working'; v_interval:=e.occurred_at;
    elsif e.type='clock_out' and v_state='working' then
      if e.occurred_at<=v_in or e.occurred_at-v_in>interval '16 hours' then
        raise exception 'invalid session duration' using errcode='P0001';
      end if;
      v_session:=v_session+floor(extract(epoch from e.occurred_at-v_interval)/60)::integer;
      v_day:=(v_in at time zone m.time_zone)::date;
      if v_day>=p_period and v_day<p_period+7 then
        if not exists(select 1 from app.accounting_roster_day
          where organization_id=p_org and period_start=p_period and user_id=p_user and work_date=v_day) then
          raise exception 'punch outside attested historical eligibility' using errcode='P0001';
        end if;
        v_minutes:=jsonb_set(v_minutes,array[v_day::text],to_jsonb(coalesce((v_minutes->>v_day::text)::integer,0)+v_session));
      end if;
      v_state:='off';
    else
      raise exception 'unresolved attendance sequence' using errcode='P0001';
    end if;
  end loop;
  if v_state<>'off' then raise exception 'open attendance session' using errcode='P0001'; end if;
  if exists(select 1 from public.approval_requests r
    where r.organization_id=p_org and r.requester_id=p_user and r.status='pending'
    and r.kind in ('overtime','correction')
    and (r.payload->>'date')::date between p_period and p_period+6) then
    raise exception 'pending attendance or overtime review' using errcode='P0001';
  end if;
  for d in select * from app.accounting_roster_day
    where organization_id=p_org and period_start=p_period and user_id=p_user order by work_date
  loop
    n:=coalesce((v_minutes->>d.work_date::text)::integer,0);
    o:=greatest(0,n-d.regular_minutes);
    if o<d.minimum_ot_minutes then o:=0; end if;
    select coalesce(sum((payload->>'minutes')::integer),0)::integer into a
      from public.approval_requests where organization_id=p_org and requester_id=p_user
      and kind='overtime' and status='approved' and (payload->>'date')::date=d.work_date;
    q:=least(o,a);
    v_worked:=v_worked+n; v_ot:=v_ot+o; v_approved:=v_approved+q; v_unapproved:=v_unapproved+o-q;
    v_rows:=v_rows||jsonb_build_array(jsonb_build_object('date',d.work_date,'worked',n,
      'regular',least(n,d.regular_minutes),'overtime',o,'approvedOvertime',q,
      'unapprovedOvertime',o-q,'excess',greatest(0,n-d.regular_minutes-o),'policy',d.policy_reference));
  end loop;
  return jsonb_build_object('worked',v_worked,'overtime',v_ot,'approvedOvertime',v_approved,
    'unapprovedOvertime',v_unapproved,'days',v_rows,'events',v_evidence,'timezone',m.time_zone);
end $$;

-- A one-use, private transaction ticket lets the existing approval chain
-- accept only the exact server-computed timesheet request. Generic clients
-- cannot insert tickets or execute these private candidate functions.
create or replace function app.block_unverified_timesheet_request() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind='timesheet' then
    delete from app.accounting_request_ticket where organization_id=new.organization_id
      and user_id=new.requester_id and payload=new.payload and backend_pid=pg_backend_pid()
      and transaction_id=txid_current();
    if not found then raise exception 'Timesheet accounting is not enabled for live workspaces' using errcode='42501'; end if;
  end if;
  return new;
end $$;

create function app.accounting_submit(p_org uuid,p_period date) returns uuid
language plpgsql set search_path = '' as $$
declare v_user uuid:=auth.uid(); r jsonb; payload jsonb; sheet public.timesheets; req public.approval_requests;
begin
  if v_user is null or not app.has_permission(p_org,'timesheet.submit',v_user) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  -- Conservative staging transaction barrier. Optimize per-tenant concurrency
  -- only after the lock protocol and write paths have been independently tested.
  lock table public.attendance_events, public.approval_requests, public.timesheets,
    public.payroll_periods, app.accounting_period_manifest, app.accounting_roster_day,
    app.accounting_submission in share row exclusive mode;
  if exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=p_period) then
    raise exception 'period already locked' using errcode='P0001';
  end if;
  r:=app.accounting_reconcile(p_org,p_period,v_user);
  insert into public.timesheets(organization_id,user_id,period_start)
    values(p_org,v_user,p_period) on conflict do nothing;
  select * into sheet from public.timesheets where organization_id=p_org and user_id=v_user and period_start=p_period for update;
  if sheet.status not in ('draft','returned') then raise exception 'invalid timesheet transition' using errcode='P0001'; end if;
  update public.timesheets set status='submitted',worked_minutes=(r->>'worked')::integer,
    overtime_minutes=(r->>'overtime')::integer,submitted_at=now(),decided_at=null
    where id=sheet.id;
  insert into app.accounting_submission values(p_org,p_period,v_user,r,sheet.id)
    on conflict (organization_id,period_start,user_id) do update set reconciliation=excluded.reconciliation,sheet_id=excluded.sheet_id;
  payload:=jsonb_build_object('periodStart',p_period,'minutes',(r->>'worked')::integer,'overtimeMinutes',(r->>'overtime')::integer);
  insert into app.accounting_request_ticket values(p_org,v_user,payload,pg_backend_pid(),txid_current());
  req:=public.submit_request(p_org,'timesheet',payload);
  return req.id;
end $$;

create function app.accounting_lock(p_org uuid,p_period date) returns void
language plpgsql set search_path = '' as $$
declare v_user uuid:=auth.uid(); u uuid; r jsonb; s app.accounting_submission;
begin
  if v_user is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  lock table public.attendance_events, public.approval_requests, public.timesheets,
    public.payroll_periods, app.accounting_period_manifest, app.accounting_roster_day,
    app.accounting_submission in share row exclusive mode;
  if exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=p_period) then
    raise exception 'period already locked' using errcode='P0001';
  end if;
  if not exists(select 1 from app.accounting_period_manifest where organization_id=p_org and period_start=p_period and sealed) then
    raise exception 'sealed historical roster required' using errcode='P0001';
  end if;
  if exists(select 1 from public.timesheets t where t.organization_id=p_org and t.period_start=p_period
    and not exists(select 1 from app.accounting_roster_day d where d.organization_id=p_org and d.period_start=p_period and d.user_id=t.user_id)) then
    raise exception 'timesheet outside roster' using errcode='P0001';
  end if;
  for u in select distinct user_id from app.accounting_roster_day where organization_id=p_org and period_start=p_period order by user_id
  loop
    r:=app.accounting_reconcile(p_org,p_period,u);
    select * into s from app.accounting_submission where organization_id=p_org and period_start=p_period and user_id=u;
    if not found or s.reconciliation is distinct from r or (r->>'unapprovedOvertime')::integer>0 then
      raise exception 'missing, changed or unreconciled timesheet' using errcode='P0001';
    end if;
    if not exists(select 1 from public.timesheets t where t.id=s.sheet_id and t.organization_id=p_org
      and t.user_id=u and t.period_start=p_period and t.status='approved'
      and t.worked_minutes=(r->>'worked')::integer and t.overtime_minutes=(r->>'overtime')::integer) then
      raise exception 'approved authoritative timesheet required' using errcode='P0001';
    end if;
    insert into app.accounting_locked_snapshot values(p_org,p_period,u,r);
  end loop;
  update public.timesheets set status='locked',locked_at=now()
    where organization_id=p_org and period_start=p_period and status='approved';
  insert into public.payroll_periods(organization_id,period_start,locked_by) values(p_org,p_period,v_user);
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,v_user,'payroll.locked','payroll_period',p_period::text,jsonb_build_object('source','authoritative-candidate-v1'));
end $$;

revoke all on function app.accounting_guard_manifest(),app.accounting_guard_roster(),
  app.accounting_reconcile(uuid,date,uuid),app.accounting_submit(uuid,date),
  app.accounting_lock(uuid,date),app.block_unverified_timesheet_request()
from public,anon,authenticated,service_role;
