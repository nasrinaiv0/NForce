
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
    'app.accounting_submission','app.accounting_locked_snapshot','app.accounting_employee_history',
    'app.accounting_policy_history','app.accounting_calendar_history','app.accounting_day_policy',
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
  foreign key(organization_id,user_id,effective_on) references app.accounting_employee_history
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
declare e app.accounting_lifecycle_event; p app.accounting_policy_history; d date; old_d date;
begin
  if auth.uid() is null or not app.has_permission(p_org,'people.manage') or not app.has_permission(p_org,'schedule.manage') then raise exception 'forbidden' using errcode='42501'; end if;
  perform app.accounting_tenant_lock(p_org);
  select * into e from app.accounting_lifecycle_event where organization_id=p_org and id=p_event;
  if not found then raise exception 'event unavailable' using errcode='P0002'; end if;
  select effective_on into old_d from app.accounting_lifecycle_ingestion where event_id=p_event and organization_id=p_org;
  if found then return old_d; end if;
  select * into p from app.accounting_policy_history where organization_id=p_org and effective_on<=(e.observed_at at time zone time_zone)::date order by effective_on desc limit 1;
  if not found then raise exception 'historical timezone policy missing' using errcode='P0001'; end if;
  d:=(e.observed_at at time zone p.time_zone)::date+case when e.operation='created' then 0 else 1 end;
  if e.operation='changed' and not exists(select 1 from app.accounting_employee_history h where h.organization_id=p_org and h.user_id=e.user_id and h.effective_on<d) then raise exception 'attested employee baseline required' using errcode='P0001'; end if;
  if exists(select 1 from app.accounting_lifecycle_event x where x.organization_id=p_org and x.user_id=e.user_id and x.id<e.id
    and not exists(select 1 from app.accounting_lifecycle_ingestion i where i.event_id=x.id)) then raise exception 'earlier event requires reconciliation' using errcode='P0001'; end if;
  insert into app.accounting_employee_history(organization_id,user_id,effective_on,eligible,shift_start,shift_end,rest_days,source_reference,recorded_by)
    values(p_org,e.user_id,d,e.status='active',e.shift_start,e.shift_end,e.rest_days,'observed lifecycle event '||e.id,auth.uid());
  insert into app.accounting_lifecycle_ingestion(event_id,organization_id,user_id,effective_on,ingested_by) values(e.id,p_org,e.user_id,d,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.lifecycle_ingested','membership',e.user_id::text,jsonb_build_object('eventId',e.id,'effectiveOn',d));
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

create or replace function app.accounting_record_employee(p_org uuid,p_user uuid,p_effective date,p_eligible boolean,p_start time,p_end time,
  p_rest smallint[],p_reference text) returns void language plpgsql set search_path='' as $$
begin
  if auth.uid() is null or not app.has_permission(p_org,'people.manage',p_user) or not app.has_permission(p_org,'schedule.manage',p_user) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  perform app.accounting_tenant_lock(p_org);
  insert into app.accounting_employee_history(organization_id,user_id,effective_on,eligible,shift_start,shift_end,rest_days,source_reference,recorded_by)
    values(p_org,p_user,p_effective,p_eligible,p_start,p_end,p_rest,p_reference,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.employee_history','membership',p_user::text,jsonb_build_object('effectiveOn',p_effective,'eligible',p_eligible));
end $$;

create or replace function app.accounting_record_policy(p_org uuid,p_effective date,p_zone text,p_regular int,p_min_ot int,
  p_night_start int,p_night_end int,p_night_factor numeric,p_day_rates jsonb,p_ot_factors jsonb,p_reference text)
returns void language plpgsql set search_path='' as $$
declare k text;
begin
  if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names where name=p_zone) then raise exception 'invalid timezone' using errcode='22023'; end if;
  if jsonb_typeof(p_day_rates) is distinct from 'object' or jsonb_typeof(p_ot_factors) is distinct from 'object' then raise exception 'invalid rates' using errcode='22023'; end if;
  foreach k in array array['REG','RD','SH','SH_RD','RH','RH_RD'] loop
    if jsonb_typeof(p_day_rates->k) is distinct from 'number' or jsonb_typeof(p_ot_factors->k) is distinct from 'number'
      or (p_day_rates->>k)::numeric not between 1 and 10 or (p_ot_factors->>k)::numeric not between 1 and 10 then
      raise exception 'missing or invalid rate: %',k using errcode='22023';
    end if;
  end loop;
  perform app.accounting_tenant_lock(p_org);
  insert into app.accounting_policy_history(organization_id,effective_on,time_zone,regular_minutes,minimum_ot_minutes,night_start,night_end,night_factor,day_rates,overtime_factors,source_reference,recorded_by)
    values(p_org,p_effective,p_zone,p_regular,p_min_ot,p_night_start,p_night_end,p_night_factor,p_day_rates,p_ot_factors,p_reference,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.policy_history','policy',p_effective::text,'{}');
end $$;

create or replace function app.accounting_record_calendar(p_org uuid,p_day date,p_kind text,p_reference text)
returns void language plpgsql set search_path='' as $$
begin
  if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
  perform app.accounting_tenant_lock(p_org);
  insert into app.accounting_calendar_history values(p_org,p_day,p_kind,p_reference,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.calendar_history','calendar',p_day::text,jsonb_build_object('kind',p_kind));
end $$;

create or replace function app.accounting_materialize_week(p_org uuid,p_period date,p_reference text)
returns void language plpgsql set search_path='' as $$
declare d date; m public.memberships; h app.accounting_employee_history; p app.accounting_policy_history;
  c app.accounting_calendar_history; z text; code text; rest boolean;
begin
  if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'schedule.manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if p_period is null or extract(isodow from p_period)<>1 then raise exception 'Monday required' using errcode='22023'; end if;
  -- Consistent with P0.2 locking order; membership write barrier is acquired first.
  perform app.accounting_tenant_lock(p_org);
  select time_zone into z from app.accounting_policy_history where organization_id=p_org and effective_on<=p_period order by effective_on desc limit 1;
  if not found then raise exception 'missing historical policy' using errcode='P0001'; end if;
  if now() < ((p_period+7)::timestamp at time zone z)+interval '16 hours' then raise exception 'week not closed' using errcode='P0001'; end if;
  insert into app.accounting_period_manifest values(p_org,p_period,z,p_reference,auth.uid(),false);
  for d in select p_period+i from generate_series(0,6)i loop
    select * into p from app.accounting_policy_history where organization_id=p_org and effective_on<=d order by effective_on desc limit 1;
    if not found or p.time_zone<>z then raise exception 'missing or changed historical timezone' using errcode='P0001'; end if;
    select * into c from app.accounting_calendar_history where organization_id=p_org and work_date=d;
    if not found then raise exception 'missing historical calendar for %',d using errcode='P0001'; end if;
    for m in select * from public.memberships where organization_id=p_org order by user_id loop
      select * into h from app.accounting_employee_history where organization_id=p_org and user_id=m.user_id and effective_on<=d order by effective_on desc limit 1;
      if not found then raise exception 'missing employee history for %',d using errcode='P0001'; end if;
      if not h.eligible then continue; end if;
      rest:=extract(isodow from d)::smallint=any(h.rest_days);
      code:=case c.holiday_kind when 'regular' then case when rest then 'RH_RD' else 'RH' end
        when 'special' then case when rest then 'SH_RD' else 'SH' end else case when rest then 'RD' else 'REG' end end;
      insert into app.accounting_roster_day values(p_org,p_period,m.user_id,d,p.regular_minutes,p.minimum_ot_minutes,p.source_reference);
      insert into app.accounting_day_policy values(p_org,p_period,m.user_id,d,h.effective_on,p.effective_on,h.shift_start,h.shift_end,
        code,(p.day_rates->>code)::numeric,(p.overtime_factors->>code)::numeric,p.night_start,p.night_end,p.night_factor);
    end loop;
  end loop;
  update app.accounting_period_manifest set sealed=true where organization_id=p_org and period_start=p_period;
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.roster_sealed','payroll_period',p_period::text,jsonb_build_object('reference',p_reference));
end $$;

create or replace function app.accounting_history_guard() returns trigger
language plpgsql set search_path='' as $$
declare v_date date;
begin
  -- Shared order: manifest, then history rows. Candidate writes are serialized.
  perform app.accounting_tenant_lock(new.organization_id);
  if tg_table_name='accounting_calendar_history' then v_date:=(to_jsonb(new)->>'work_date')::date;
  else v_date:=(to_jsonb(new)->>'effective_on')::date; end if;
  if exists(select 1 from app.accounting_period_manifest
    where organization_id=new.organization_id and sealed and v_date<period_start+7) then
    raise exception 'history intersects sealed accounting period; use audited adjustment' using errcode='42501';
  end if;
  return new;
end $$;

create or replace function app.accounting_propose_adjustment(p_org uuid,p_period date,p_user uuid,p_code text,p_delta int,
  p_reason text,p_evidence text,p_key text) returns uuid language plpgsql set search_path='' as $$
declare v_id uuid; v_old app.accounting_adjustment_proposal;
begin
  if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
  perform app.accounting_tenant_lock(p_org);
  select * into v_old from app.accounting_adjustment_proposal where organization_id=p_org and idempotency_key=p_key;
  if found then
    if (v_old.period_start,v_old.user_id,v_old.pay_code,v_old.delta_minutes,v_old.reason,v_old.evidence_reference,v_old.proposed_by)
      is distinct from (p_period,p_user,p_code,p_delta,p_reason,p_evidence,auth.uid()) then raise exception 'idempotency conflict' using errcode='22023'; end if;
    return v_old.id;
  end if;
  if not exists(select 1 from app.accounting_locked_snapshot s cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l
    where s.organization_id=p_org and s.period_start=p_period and s.user_id=p_user and l->>'code'=p_code) then
    raise exception 'locked classified pay code required' using errcode='P0001';
  end if;
  insert into app.accounting_adjustment_proposal(organization_id,period_start,user_id,pay_code,delta_minutes,reason,evidence_reference,idempotency_key,proposed_by)
    values(p_org,p_period,p_user,p_code,p_delta,p_reason,p_evidence,p_key,auth.uid()) returning id into v_id;
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.adjustment_proposed','adjustment',v_id::text,'{}');
  return v_id;
end $$;

create or replace function app.accounting_decide_adjustment(p_id uuid,p_approve boolean,p_reason text)
returns void language plpgsql set search_path='' as $$
declare a app.accounting_adjustment_proposal; v_minutes bigint;
begin
  
  select * into a from app.accounting_adjustment_proposal where id=p_id;
  if not found or auth.uid() is null or auth.uid() in (a.proposed_by,a.user_id) or not app.has_permission(a.organization_id,'timesheet.adjust') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  perform app.accounting_tenant_lock(a.organization_id);
  if not app.has_permission(a.organization_id,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
  if p_approve then
    select coalesce(sum((l->>'minutes')::int),0) into v_minutes from app.accounting_locked_snapshot s
      cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l
      where s.organization_id=a.organization_id and s.period_start=a.period_start and s.user_id=a.user_id and l->>'code'=a.pay_code;
    select v_minutes+coalesce(sum(p.delta_minutes),0) into v_minutes from app.accounting_adjustment_proposal p
      join app.accounting_adjustment_decision d on d.proposal_id=p.id and d.approved
      where p.organization_id=a.organization_id and p.period_start=a.period_start and p.user_id=a.user_id and p.pay_code=a.pay_code;
    if v_minutes+a.delta_minutes<0 then raise exception 'negative adjusted pay-code balance' using errcode='P0001'; end if;
  end if;
  insert into app.accounting_adjustment_decision(proposal_id,approved,reason,decided_by) values(p_id,p_approve,p_reason,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(a.organization_id,auth.uid(),'accounting.adjustment_decided','adjustment',p_id::text,jsonb_build_object('approved',p_approve));
end $$;
