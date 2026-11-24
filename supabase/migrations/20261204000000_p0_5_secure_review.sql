
-- P0.5: private staging acceptance control. Never seed or enable in production.
create table app.accounting_review_access (
  organization_id uuid primary key references public.organizations(id),
  evidence_reference text not null check(length(btrim(evidence_reference)) between 8 and 250),
  enabled_by uuid not null references auth.users(id),
  expires_at timestamptz not null,
  enabled_at timestamptz not null default now(),
  check(expires_at>enabled_at and expires_at<=enabled_at+interval '7 days')
);
alter table app.accounting_review_access enable row level security;
revoke all on app.accounting_review_access from public,anon,authenticated,service_role;
create trigger p05_review_access_barrier before insert or update or delete on app.accounting_review_access
for each row execute function app.accounting_write_barrier();

-- Authorization mutation barrier. Tenant role and membership grant mutations
-- share the accounting lock; platform role templates are migration-owned.
create function app.accounting_auth_barrier() returns trigger
language plpgsql security definer set search_path='' as $$
declare old_org uuid; new_org uuid; o uuid;
begin
  if tg_table_name='membership_roles' then
    if tg_op<>'INSERT' then select organization_id into old_org from public.memberships where id=old.membership_id; end if;
    if tg_op<>'DELETE' then select organization_id into new_org from public.memberships where id=new.membership_id; end if;
  elsif tg_table_name='role_grants' then
    if tg_op<>'INSERT' then select organization_id into old_org from public.roles where id=old.role_id; end if;
    if tg_op<>'DELETE' then select organization_id into new_org from public.roles where id=new.role_id; end if;
  else
    if tg_op<>'INSERT' then old_org:=old.organization_id; end if;
    if tg_op<>'DELETE' then new_org:=new.organization_id; end if;
  end if;
  if tg_op='UPDATE' and old_org is distinct from new_org then raise exception 'tenant immutable' using errcode='42501'; end if;
  o:=coalesce(new_org,old_org);
  if o is not null and not pg_try_advisory_xact_lock(hashtextextended('nforce-accounting-v4:'||o::text,0)) then
    raise exception 'authorization tenant busy; retry transaction' using errcode='40001'; end if;
  if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger a_p05_auth_barrier before insert or update or delete on public.membership_roles for each row execute function app.accounting_auth_barrier();
create trigger a_p05_auth_barrier before insert or update or delete on public.role_grants for each row execute function app.accounting_auth_barrier();
create trigger a_p05_auth_barrier before insert or update or delete on public.roles for each row execute function app.accounting_auth_barrier();
create trigger a_p05_auth_barrier before insert or update or delete on public.delegations for each row execute function app.accounting_auth_barrier();
create trigger a_p05_auth_barrier before insert or update or delete on public.team_members for each row execute function app.accounting_auth_barrier();
create trigger a_p05_auth_barrier before insert or update or delete on public.approval_steps for each row execute function app.accounting_auth_barrier();

-- Staging-only operator workflow. Propose immutable ordered event IDs, then
-- apply all in one transaction under independent current authorization.
create table app.accounting_ingestion_batch (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  event_ids bigint[] not null check(cardinality(event_ids) between 1 and 100),
  reference text not null check(length(btrim(reference)) between 8 and 250),
  request_key text not null check(length(request_key) between 8 and 128),
  prepared_by uuid not null references auth.users(id),
  prepared_at timestamptz not null default now(),
  unique(organization_id,request_key)
);
create table app.accounting_ingestion_batch_decision (
  batch_id uuid primary key references app.accounting_ingestion_batch(id),
  approved_by uuid not null references auth.users(id),
  approved_at timestamptz not null default now()
);
alter table app.accounting_ingestion_batch enable row level security;
alter table app.accounting_ingestion_batch_decision enable row level security;
revoke all on app.accounting_ingestion_batch,app.accounting_ingestion_batch_decision from public,anon,authenticated,service_role;
create trigger p05_immutable before update or delete on app.accounting_ingestion_batch for each row execute function app.forbid_mutation();
create trigger p05_immutable before update or delete on app.accounting_ingestion_batch_decision for each row execute function app.forbid_mutation();
create function app.accounting_prepare_ingestion(p_org uuid,p_ids bigint[],p_reference text,p_key text)
returns uuid language plpgsql set search_path='' as $$
declare b app.accounting_ingestion_batch; v_id uuid;
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or not app.has_permission(p_org,'people.manage') or not app.has_permission(p_org,'schedule.manage') then raise exception 'forbidden' using errcode='42501'; end if;
  if p_ids is null or cardinality(p_ids) not between 1 and 100 or array_position(p_ids,null) is not null
    or cardinality(p_ids)<>(select count(distinct x) from unnest(p_ids)x)
    or p_ids is distinct from (select array_agg(x order by x) from unnest(p_ids)x)
    or cardinality(p_ids)<>(select count(*) from app.accounting_lifecycle_event where organization_id=p_org and id=any(p_ids))
    then raise exception 'invalid ingestion batch' using errcode='22023'; end if;
  select * into b from app.accounting_ingestion_batch where organization_id=p_org and request_key=p_key;
  if found then
    if (b.event_ids,b.reference,b.prepared_by) is distinct from (p_ids,p_reference,auth.uid()) then raise exception 'idempotency conflict' using errcode='22023'; end if;
    return b.id;
  end if;
  insert into app.accounting_ingestion_batch(organization_id,event_ids,reference,request_key,prepared_by)
    values(p_org,p_ids,p_reference,p_key,auth.uid()) returning id into v_id;
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.ingestion_prepared','ingestion_batch',v_id::text,jsonb_build_object('eventCount',cardinality(p_ids)));
  return v_id;
end $$;
create function app.accounting_approve_ingestion(p_org uuid,p_id uuid)
returns void language plpgsql set search_path='' as $$
declare b app.accounting_ingestion_batch; e bigint;
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or not app.has_permission(p_org,'people.manage') or not app.has_permission(p_org,'schedule.manage') then raise exception 'forbidden' using errcode='42501'; end if;
  select * into b from app.accounting_ingestion_batch where organization_id=p_org and id=p_id;
  if not found or b.prepared_by=auth.uid() then raise exception 'independent review required' using errcode='42501'; end if;
  if exists(select 1 from app.accounting_ingestion_batch_decision where batch_id=p_id) then raise exception 'batch already applied' using errcode='P0001'; end if;
  foreach e in array b.event_ids loop perform app.accounting_ingest_lifecycle(p_org,e); end loop;
  insert into app.accounting_ingestion_batch_decision(batch_id,approved_by) values(p_id,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.ingestion_applied','ingestion_batch',p_id::text,jsonb_build_object('eventCount',cardinality(b.event_ids)));
end $$;

-- Read-only, limited aggregate RPC. No pay amounts, identities, raw punches,
-- exports or writes. Disabled unless a privileged administrator explicitly
-- grants a short-lived fictional-tenant acceptance window outside this PR.
create function public.accounting_review_snapshot(p_organization_id uuid,p_period_start date,p_scope text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb; u uuid:=auth.uid(); n int;
begin
  if u is null or p_scope is null or p_scope not in ('self','organization') or p_period_start is null or extract(isodow from p_period_start)<>1 then
    raise exception 'accounting review unavailable' using errcode='42501'; end if;
  perform app.accounting_tenant_lock(p_organization_id);
  if not app.is_member(p_organization_id) or (p_scope='organization' and not app.has_permission(p_organization_id,'payroll.prepare'))
    or not exists(select 1 from app.accounting_review_access g where g.organization_id=p_organization_id and g.expires_at>clock_timestamp()) then
    raise exception 'accounting review unavailable' using errcode='42501'; end if;
  if not exists(select 1 from public.payroll_periods where organization_id=p_organization_id and period_start=p_period_start) then
    raise exception 'locked review unavailable' using errcode='P0001'; end if;
  select count(*) into n from app.accounting_locked_snapshot s where s.organization_id=p_organization_id and s.period_start=p_period_start
    and (p_scope='organization' or s.user_id=u);
  if n=0 or exists(select 1 from app.accounting_locked_snapshot s where s.organization_id=p_organization_id and s.period_start=p_period_start
    and (p_scope='organization' or s.user_id=u) and (s.reconciliation->>'classificationVersion' is distinct from '3' or jsonb_typeof(s.reconciliation->'payLines') is distinct from 'array')) then
    raise exception 'classified locked review unavailable' using errcode='P0001'; end if;
  with snapshots as (
    select reconciliation as x from app.accounting_locked_snapshot where organization_id=p_organization_id and period_start=p_period_start and (p_scope='organization' or user_id=u)
  ), totals as (
    select sum((x->>'worked')::int) worked,sum((x->>'approvedOvertime')::int) ot from snapshots
  ), codes as (
    select l->>'code' code,sum((l->>'minutes')::int) minutes from snapshots cross join lateral jsonb_array_elements(x->'payLines')l group by 1
  )
  select jsonb_build_object('organizationId',p_organization_id,'periodStart',p_period_start,'scope',p_scope,
    'employeeCount',n,'workedMinutes',totals.worked,'approvedOvertimeMinutes',totals.ot,'source','locked-original-v3',
    'lines',coalesce((select jsonb_agg(jsonb_build_object('code',code,'minutes',minutes) order by code) from codes),'[]'::jsonb))
    into r from totals;
  return r;
end $$;
revoke all on function app.accounting_auth_barrier(),app.accounting_prepare_ingestion(uuid,bigint[],text,text),app.accounting_approve_ingestion(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.accounting_review_snapshot(uuid,date,text) from public,anon,authenticated,service_role;
grant execute on function public.accounting_review_snapshot(uuid,date,text) to authenticated;

create or replace function app.accounting_submit(p_org uuid,p_period date) returns uuid
language plpgsql set search_path = '' as $$
declare v_user uuid:=auth.uid(); r jsonb; payload jsonb; sheet public.timesheets; req public.approval_requests;
begin
  perform app.accounting_tenant_lock(p_org);
  if v_user is null or not app.has_permission(p_org,'timesheet.submit',v_user) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  -- Conservative staging transaction barrier. Optimize per-tenant concurrency
  -- only after the lock protocol and write paths have been independently tested.
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
  perform app.accounting_tenant_lock(p_org);
  if v_user is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then
    raise exception 'forbidden' using errcode='42501';
  end if;
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
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or not app.has_permission(p_org,'people.manage',p_user) or not app.has_permission(p_org,'schedule.manage',p_user) then
    raise exception 'forbidden' using errcode='42501';
  end if;
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
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names where name=p_zone) then raise exception 'invalid timezone' using errcode='22023'; end if;
  if jsonb_typeof(p_day_rates) is distinct from 'object' or jsonb_typeof(p_ot_factors) is distinct from 'object' then raise exception 'invalid rates' using errcode='22023'; end if;
  foreach k in array array['REG','RD','SH','SH_RD','RH','RH_RD'] loop
    if jsonb_typeof(p_day_rates->k) is distinct from 'number' or jsonb_typeof(p_ot_factors->k) is distinct from 'number'
      or (p_day_rates->>k)::numeric not between 1 and 10 or (p_ot_factors->>k)::numeric not between 1 and 10 then
      raise exception 'missing or invalid rate: %',k using errcode='22023';
    end if;
  end loop;
  insert into app.accounting_policy_history(organization_id,effective_on,time_zone,regular_minutes,minimum_ot_minutes,night_start,night_end,night_factor,day_rates,overtime_factors,source_reference,recorded_by)
    values(p_org,p_effective,p_zone,p_regular,p_min_ot,p_night_start,p_night_end,p_night_factor,p_day_rates,p_ot_factors,p_reference,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.policy_history','policy',p_effective::text,'{}');
end $$;

create or replace function app.accounting_record_calendar(p_org uuid,p_day date,p_kind text,p_reference text)
returns void language plpgsql set search_path='' as $$
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
  insert into app.accounting_calendar_history values(p_org,p_day,p_kind,p_reference,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.calendar_history','calendar',p_day::text,jsonb_build_object('kind',p_kind));
end $$;

create or replace function app.accounting_materialize_week(p_org uuid,p_period date,p_reference text)
returns void language plpgsql set search_path='' as $$
declare d date; m public.memberships; h app.accounting_employee_history; p app.accounting_policy_history;
  c app.accounting_calendar_history; z text; code text; rest boolean;
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'schedule.manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if p_period is null or extract(isodow from p_period)<>1 then raise exception 'Monday required' using errcode='22023'; end if;
  -- Consistent with P0.2 locking order; membership write barrier is acquired first.
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

create or replace function app.accounting_ingest_lifecycle(p_org uuid,p_event bigint) returns date
language plpgsql set search_path='' as $$
declare e app.accounting_lifecycle_event; p app.accounting_policy_history; d date; old_d date;
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or not app.has_permission(p_org,'people.manage') or not app.has_permission(p_org,'schedule.manage') then raise exception 'forbidden' using errcode='42501'; end if;
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

create or replace function app.accounting_propose_adjustment(p_org uuid,p_period date,p_user uuid,p_code text,p_delta int,
  p_reason text,p_evidence text,p_key text) returns uuid language plpgsql set search_path='' as $$
declare v_id uuid; v_old app.accounting_adjustment_proposal;
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
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
