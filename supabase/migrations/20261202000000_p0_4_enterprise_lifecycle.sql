
-- Private candidate. Public accounting release gates remain closed.
create function app.accounting_tenant_lock(p_org uuid) returns void
language plpgsql set search_path='' as $$
begin
  if p_org is null or current_setting('transaction_isolation')<>'read committed' then
    raise exception 'accounting requires READ COMMITTED' using errcode='25000'; end if;
  perform pg_advisory_xact_lock(hashtextextended('nforce-accounting-v4:'||p_org::text,0));
end $$;
create function app.accounting_write_barrier() returns trigger
language plpgsql set search_path='' as $$
declare o uuid;
begin
  o:=case when tg_op='DELETE' then old.organization_id else new.organization_id end;
  if tg_op='UPDATE' and old.organization_id is distinct from new.organization_id then
    raise exception 'tenant immutable' using errcode='42501'; end if;
  if not pg_try_advisory_xact_lock(hashtextextended('nforce-accounting-v4:'||o::text,0)) then
    raise exception 'accounting tenant busy; retry transaction' using errcode='40001'; end if;
  if tg_op='DELETE' then return old; end if; return new;
end $$;
do $$
declare s text;
begin
  foreach s in array array['public.memberships','public.attendance_events','public.approval_requests',
    'public.timesheets','public.payroll_periods','app.accounting_period_manifest','app.accounting_roster_day',
    'app.accounting_submission','app.accounting_locked_snapshot','app.ph_employment_history',
    'app.ph_shift_history','app.ph_site_calendar_history','app.ph_workday_evidence','app.ph_workday_sources',
    'app.accounting_adjustment_proposal'] loop
    execute format('create trigger a_p04_tenant_barrier before insert or update or delete on %I.%I for each row execute function app.accounting_write_barrier()',split_part(s,'.',1),split_part(s,'.',2));
  end loop;
end $$;
create table app.accounting_lifecycle_event (
  id bigint generated always as identity primary key,
  organization_id uuid not null, user_id uuid not null,
  observed_at timestamptz not null default clock_timestamp(), actor_id uuid,
  operation text not null check(operation in ('created','changed')),
  status public.membership_status not null, shift_start time not null, shift_end time not null,
  rest_days smallint[] not null, department_id uuid, reports_to uuid,
  foreign key(organization_id,user_id) references public.memberships(organization_id,user_id)
);
create table app.accounting_lifecycle_ingestion (
  event_id bigint primary key references app.accounting_lifecycle_event(id),
  organization_id uuid not null,user_id uuid not null,effective_on date not null,
  ingested_by uuid not null references auth.users(id),ingested_at timestamptz not null default now(),
  employment_recorded_at timestamptz not null, shift_recorded_at timestamptz not null,
  foreign key(organization_id,user_id,effective_on,shift_recorded_at) references app.ph_shift_history(organization_id,user_id,effective_on,recorded_at),
  foreign key(organization_id,user_id,effective_on,employment_recorded_at) references app.ph_employment_history
);
do $$
declare n text;
begin
  foreach n in array array['accounting_lifecycle_event','accounting_lifecycle_ingestion'] loop
    execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
    execute format('alter table app.%I enable row level security',n);
    execute format('create trigger p04_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
  end loop;
end $$;
create function app.accounting_capture_lifecycle() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_op='UPDATE' and (old.status,old.shift_start,old.shift_end,old.rest_days,old.department_id,old.reports_to)
    is not distinct from (new.status,new.shift_start,new.shift_end,new.rest_days,new.department_id,new.reports_to) then return new; end if;
  insert into app.accounting_lifecycle_event(organization_id,user_id,actor_id,operation,status,shift_start,shift_end,rest_days,department_id,reports_to)
    values(new.organization_id,new.user_id,auth.uid(),case when tg_op='INSERT' then 'created' else 'changed' end,
      new.status,new.shift_start,new.shift_end,new.rest_days,new.department_id,new.reports_to);
  return new;
end $$;
create trigger p04_capture_lifecycle after insert or update on public.memberships for each row execute function app.accounting_capture_lifecycle();
create function app.accounting_ingest_lifecycle(p_org uuid,p_event bigint) returns date
language plpgsql set search_path='' as $$
declare e app.accounting_lifecycle_event; h app.ph_employment_history; d date; old_d date; s_at timestamptz;
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or not app.has_permission(p_org,'people.manage') or not app.has_permission(p_org,'schedule.manage') then raise exception 'forbidden' using errcode='42501'; end if;
  select * into e from app.accounting_lifecycle_event where organization_id=p_org and id=p_event;
  if not found then raise exception 'event unavailable' using errcode='P0002'; end if;
  if auth.uid()=e.user_id then raise exception 'self ingestion forbidden' using errcode='42501'; end if;
  select effective_on into old_d from app.accounting_lifecycle_ingestion where event_id=p_event and organization_id=p_org;
  if found then return old_d; end if;
  d:=(e.observed_at at time zone 'Asia/Manila')::date+case when e.operation='created' then 0 else 1 end;
  if e.status not in ('active','ended') then raise exception 'ambiguous employment state' using errcode='P0001'; end if;
  h:=app.ph_employment_as_of(p_org,e.user_id,d,clock_timestamp());
  if h.status<>(case when e.status='active' then 'employed' else 'separated' end) or h.effective_on<>d then
    raise exception 'exact dated attested employment evidence required' using errcode='P0001'; end if;
  if exists(select 1 from app.accounting_lifecycle_event x where x.organization_id=p_org and x.user_id=e.user_id and x.id<e.id
    and not exists(select 1 from app.accounting_lifecycle_ingestion i where i.event_id=x.id)) then raise exception 'earlier event requires reconciliation' using errcode='P0001'; end if;
  if exists(select 1 from app.accounting_period_manifest where organization_id=p_org and sealed and d<period_start+7) then raise exception 'sealed history requires adjustment' using errcode='42501'; end if;
  if exists(select 1 from app.ph_shift_history where organization_id=p_org and user_id=e.user_id and effective_on=d) then raise exception 'same-day shift evidence requires reconciliation' using errcode='P0001'; end if;
  insert into app.ph_shift_history(organization_id,user_id,effective_on,start_local,end_local,rest_days,source_reference,recorded_by)
    values(p_org,e.user_id,d,e.shift_start,e.shift_end,e.rest_days,'observed lifecycle event '||e.id,auth.uid()) returning recorded_at into s_at;
  insert into app.accounting_lifecycle_ingestion(event_id,organization_id,user_id,effective_on,ingested_by,employment_recorded_at,shift_recorded_at)
    values(e.id,p_org,e.user_id,d,auth.uid(),h.recorded_at,s_at);
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.lifecycle_ingested','membership',e.user_id::text,jsonb_build_object('eventId',e.id,'effectiveOn',d));
  return d;
end $$;
create function app.accounting_guard_locked_correction() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.source='correction' and exists(select 1 from public.payroll_periods p join app.accounting_period_manifest m on m.organization_id=p.organization_id and m.period_start=p.period_start
    where p.organization_id=new.organization_id and (new.occurred_at at time zone m.time_zone)::date between p.period_start and p.period_start+7) then raise exception 'locked accounting period: use audited adjustment' using errcode='42501'; end if;
  return new;
end $$;
create trigger p04_locked_correction before insert on public.attendance_events for each row execute function app.accounting_guard_locked_correction();
revoke all on function app.accounting_tenant_lock(uuid),app.accounting_write_barrier(),app.accounting_capture_lifecycle(),app.accounting_ingest_lifecycle(uuid,bigint),app.accounting_guard_locked_correction() from public,anon,authenticated,service_role;

create or replace function app.accounting_submit(p_org uuid,p_period date) returns uuid
language plpgsql set search_path = '' as $$
declare v_user uuid:=auth.uid(); r jsonb; payload jsonb; sheet public.timesheets; req public.approval_requests;
begin
  if v_user is null or not app.has_permission(p_org,'timesheet.submit',v_user) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  -- Conservative staging transaction barrier. Optimize per-tenant concurrency
  -- only after the lock protocol and write paths have been independently tested.
  perform app.accounting_tenant_lock(p_org);
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

create or replace function app.accounting_lock(p_org uuid,p_period date) returns void
language plpgsql set search_path = '' as $$
declare v_user uuid:=auth.uid(); u uuid; r jsonb; s app.accounting_submission;
begin
  if v_user is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  perform app.accounting_tenant_lock(p_org);
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














