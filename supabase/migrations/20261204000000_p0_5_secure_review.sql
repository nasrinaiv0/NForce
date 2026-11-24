
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
    and (p_scope='organization' or s.user_id=u) and (s.reconciliation->>'classificationVersion' is distinct from '4' or jsonb_typeof(s.reconciliation->'payLines') is distinct from 'array')) then
    raise exception 'classified locked review unavailable' using errcode='P0001'; end if;
  with snapshots as (
    select reconciliation as x from app.accounting_locked_snapshot where organization_id=p_organization_id and period_start=p_period_start and (p_scope='organization' or user_id=u)
  ), totals as (
    select sum((x->>'workedSeconds')::numeric) worked,sum((x->>'overtimeSeconds')::numeric) ot from snapshots
  ), codes as (
    select l->>'code' code,sum((l->>'seconds')::numeric) seconds from snapshots cross join lateral jsonb_array_elements(x->'payLines')l group by 1
  )
  select jsonb_build_object('organizationId',p_organization_id,'periodStart',p_period_start,'scope',p_scope,
    'employeeCount',n,'workedSeconds',totals.worked::text,'overtimeSeconds',totals.ot::text,'source','locked-original-ph-v4',
    'lines',coalesce((select jsonb_agg(jsonb_build_object('code',code,'seconds',seconds::text) order by code) from codes),'[]'::jsonb))
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
    if not found or s.reconciliation is distinct from r or (r->>'unapprovedOvertime')::integer>0 or coalesce((r->>'exactOvertimeReviewSeconds')::numeric,0)>0 then
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













-- Canonical statutory operations share tenant authorization serialization.
create or replace function app.ph_record_workday(p_org uuid,p_period date,p_user uuid,p_day date,p_anchor timestamptz,p_calendar jsonb,p_reference text)
returns void language plpgsql set search_path='' as $$
declare h app.ph_employment_history; roster app.accounting_roster_day; manifest app.accounting_period_manifest; k text;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'schedule.manage',p_user) then
 raise exception 'forbidden' using errcode='42501'; end if;
 select * into manifest from app.accounting_period_manifest where organization_id=p_org and period_start=p_period for update;
 if not found or manifest.sealed or manifest.time_zone<>'Asia/Manila' then raise exception 'unavailable PH manifest' using errcode='P0001'; end if;
 select * into roster from app.accounting_roster_day where organization_id=p_org and period_start=p_period and user_id=p_user and work_date=p_day;
 if not found or roster.regular_minutes<>480 or roster.minimum_ot_minutes<>0 then raise exception 'unsupported workday policy' using errcode='P0001'; end if;
 h:=app.ph_employment_as_of(p_org,p_user,p_day,clock_timestamp());
 if h.status<>'employed' then raise exception 'not historically eligible' using errcode='P0001'; end if;
 if p_anchor is null or not isfinite(p_anchor) or (p_anchor at time zone 'Asia/Manila')::date is distinct from p_day or
 jsonb_typeof(p_calendar) is distinct from 'object' then raise exception 'invalid workday evidence' using errcode='22023'; end if;
 foreach k in array array[p_day::text,(p_day+1)::text] loop
 if p_calendar->>k is null or p_calendar->>k not in ('ordinary','rest','special','special_rest','regular_holiday','regular_holiday_rest','double_regular','double_regular_rest')
 then raise exception 'missing local calendar coverage' using errcode='22023'; end if;
 end loop;
 if exists(select 1 from app.ph_workday_evidence e where e.organization_id=p_org and e.user_id=p_user
 and e.anchor_at < p_anchor+interval '24 hours' and p_anchor < e.anchor_at+interval '24 hours')
 then raise exception 'overlapping attested workdays require review' using errcode='22023'; end if;
 insert into app.ph_workday_evidence values(p_org,p_period,p_user,p_day,p_anchor,h.effective_on,h.recorded_at,p_calendar,p_reference,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_workday_attested','membership',p_user::text,jsonb_build_object('workDate',p_day));
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
    where s.organization_id=p_org and s.period_start=p_period and s.user_id=p_user and s.reconciliation->>'classificationVersion'='4' and l->>'code'=p_code) then
    raise exception 'locked classified pay code required' using errcode='P0001';
  end if;
  insert into app.accounting_adjustment_proposal(organization_id,period_start,user_id,pay_code,delta_minutes,reason,evidence_reference,idempotency_key,proposed_by)
    values(p_org,p_period,p_user,p_code,p_delta,p_reason,p_evidence,p_key,auth.uid()) returning id into v_id;
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.adjustment_proposed','adjustment',v_id::text,'{}');
  return v_id;
end $$;

create or replace function app.ph_record_shift(p_org uuid,p_user uuid,p_effective date,p_start time,p_end time,p_rest smallint[],p_reference text)
returns void language plpgsql set search_path='' as $$
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'schedule.manage',p_user)
 then raise exception 'forbidden' using errcode='42501'; end if;
 insert into app.ph_shift_history(organization_id,user_id,effective_on,start_local,end_local,rest_days,source_reference,recorded_by)
 values(p_org,p_user,p_effective,p_start,p_end,p_rest,p_reference,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_shift_history','membership',p_user::text,jsonb_build_object('effectiveOn',p_effective));
end $$;

create or replace function app.ph_record_site_calendar(p_org uuid,p_site text,p_day date,p_kind text,p_reference text)
returns void language plpgsql set search_path='' as $$
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 insert into app.ph_site_calendar_history(organization_id,site_reference,work_date,holiday_kind,source_reference,recorded_by)
 values(p_org,p_site,p_day,p_kind,p_reference,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_calendar_history','calendar',p_day::text,jsonb_build_object('kind',p_kind));
end $$;

create or replace function app.ph_materialize_week(p_org uuid,p_period date,p_reference text)
returns void language plpgsql set search_path='' as $$
declare d date;m public.memberships;h app.ph_employment_history;sh app.ph_shift_history;nsh app.ph_shift_history;
 c app.ph_site_calendar_history;nc app.ph_site_calendar_history;k text;nk text;known_at timestamptz;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'schedule.manage')
 then raise exception 'forbidden' using errcode='42501'; end if;
 if p_period is null or not isfinite(p_period) or extract(isodow from p_period)<>1
 then raise exception 'Monday required' using errcode='22023'; end if;
 if now() < ((p_period+7)::timestamp at time zone 'Asia/Manila')+interval '16 hours'
 then raise exception 'week not closed' using errcode='P0001'; end if;
    known_at:=clock_timestamp();
 insert into app.accounting_period_manifest values(p_org,p_period,'Asia/Manila',p_reference,auth.uid(),false);
 for d in select p_period+i from generate_series(0,6)i loop
  for m in select * from public.memberships where organization_id=p_org order by user_id loop
   h:=app.ph_employment_as_of(p_org,m.user_id,d,known_at);
   if h.status<>'employed' then continue; end if;
   select * into sh from app.ph_shift_history where organization_id=p_org and user_id=m.user_id and effective_on<=d and recorded_at<=known_at
   order by effective_on desc,recorded_at desc limit 1;
   if not found then raise exception 'missing historical shift' using errcode='P0001'; end if;
   select * into nsh from app.ph_shift_history where organization_id=p_org and user_id=m.user_id and effective_on<=d+1 and recorded_at<=known_at
   order by effective_on desc,recorded_at desc limit 1;
   if not found then raise exception 'missing next-date shift evidence' using errcode='P0001'; end if;
   select * into c from app.ph_site_calendar_history where organization_id=p_org and site_reference=h.site_reference and work_date=d and recorded_at<=known_at
   order by recorded_at desc limit 1;
   if not found then raise exception 'missing historical site calendar' using errcode='P0001'; end if;
   select * into nc from app.ph_site_calendar_history where organization_id=p_org and site_reference=h.site_reference and work_date=d+1 and recorded_at<=known_at
   order by recorded_at desc limit 1;
   if not found then raise exception 'missing next-date site calendar' using errcode='P0001'; end if;
   k:=app.ph_day_kind(c.holiday_kind,extract(isodow from d)::smallint=any(sh.rest_days));
   nk:=app.ph_day_kind(nc.holiday_kind,extract(isodow from d+1)::smallint=any(nsh.rest_days));
   insert into app.accounting_roster_day values(p_org,p_period,m.user_id,d,480,0,h.wage_order_reference);
   perform app.ph_record_workday(p_org,p_period,m.user_id,d,(d+sh.start_local) at time zone 'Asia/Manila',
   jsonb_build_object(d::text,k,(d+1)::text,nk),sh.source_reference);
   if not exists(select 1 from app.ph_workday_evidence e where e.organization_id=p_org and e.period_start=p_period and e.user_id=m.user_id
   and e.work_date=d and e.employment_effective_on=h.effective_on and e.employment_recorded_at=h.recorded_at)
   then raise exception 'historical employment revision mismatch' using errcode='P0001'; end if;
   insert into app.ph_workday_sources values(p_org,p_period,m.user_id,d,sh.effective_on,sh.recorded_at,nsh.effective_on,nsh.recorded_at,
    h.site_reference,c.recorded_at,d+1,nc.recorded_at);
  end loop;
 end loop;
 update app.accounting_period_manifest set sealed=true where organization_id=p_org and period_start=p_period;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_roster_sealed','payroll_period',p_period::text,jsonb_build_object('reference',p_reference,'knownAt',known_at));
end $$;

create or replace function app.ph_open_benefit_year(p_org uuid,p_user uuid,p_through date,p_buckets jsonb,p_other numeric,p_mode text,p_evidence text)
returns void language plpgsql set search_path='' as $$
declare k text; v jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 if jsonb_typeof(p_buckets) is distinct from 'object' then raise exception 'opening buckets required' using errcode='22023'; end if;
 for k,v in select * from jsonb_each(p_buckets) loop
  if length(k)>100 or k !~ '^(rice|laundry|uniform|medical|achievement|gift|cba_productivity|dependent_medical|ot_night_meal|vacation_days):2026(-[0-9]{2}(-[0-9]{2})?|-S[12])?$' or jsonb_typeof(v)<>'number' or v::text::numeric<0 or v::text::numeric>1000000000 or v::text::numeric<>round(v::text::numeric,2)
  then raise exception 'invalid opening balance' using errcode='22023'; end if;
 end loop;
 insert into app.ph_benefit_year values(p_org,p_user,extract(year from p_through)::integer,p_through,p_buckets,p_other,p_mode,p_evidence,auth.uid());
end $$;

create or replace function app.ph_post_benefit(p_org uuid,p_user uuid,p_key text,p_day date,p_code text,p_amount numeric,p_units numeric,p_wage numeric,p_evidence text)
returns jsonb language plpgsql set search_path='' as $$
declare y app.ph_benefit_year; old app.ph_benefit_event; req jsonb; res jsonb; probe jsonb; bucket text;
 seq bigint; last_day date; prior numeric; other_prior numeric; yr integer;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_day is null or not isfinite(p_day) or p_key is null or length(p_key) not between 8 and 128
 or p_code is null or p_code not in ('rice','laundry','uniform','medical_assistance','achievement_award','christmas_anniversary_gift','cba','productivity','dependent_medical','ot_night_meal','vacation_conversion','13th_month','qualified_other_benefit')
 then raise exception 'invalid benefit event' using errcode='22023'; end if;
 yr:=extract(year from p_day)::integer;
 -- Row lock serializes all monthly/annual benefit buckets for this tenant employee year.
 select * into y from app.ph_benefit_year where organization_id=p_org and user_id=p_user and tax_year=yr for update;
 if not found then raise exception 'attested opening balances required' using errcode='P0001'; end if;
 req:=jsonb_build_object('date',p_day,'code',p_code,'amount',p_amount,'units',p_units,'wage',p_wage,'evidence',p_evidence);
 select * into old from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=yr and event_key=p_key;
 if found then
  if old.request is distinct from req then raise exception 'idempotency conflict' using errcode='22023'; end if;
  return old.result;
 end if;
 select coalesce(max(sequence_no),0),max(paid_on) into seq,last_day from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=yr;
 if p_day<=y.opening_through or (last_day is not null and p_day<last_day) then raise exception 'backdated benefit requires reviewed replay' using errcode='22023'; end if;
 probe:=app.ph_compensation_classify(p_day,p_code,p_amount,0,0,false,p_evidence,p_units,p_wage,y.medical_mode);
 bucket:=probe->>'bucket';
 prior:=coalesce((y.opening_buckets->>bucket)::numeric,0);
 if bucket is not null then
 select coalesce((select (e.result->>'bucketUsage')::numeric from app.ph_benefit_event e
 where e.organization_id=p_org and e.user_id=p_user and e.tax_year=yr and e.result->>'bucket'=bucket order by sequence_no desc limit 1),prior) into prior;
 end if;
 select coalesce((select (e.result->>'otherBenefitUsage')::numeric from app.ph_benefit_event e
 where e.organization_id=p_org and e.user_id=p_user and e.tax_year=yr order by sequence_no desc limit 1),y.opening_other) into other_prior;
 res:=app.ph_compensation_classify(p_day,p_code,p_amount,prior,other_prior,false,p_evidence,p_units,p_wage,y.medical_mode);
 insert into app.ph_benefit_event values(p_org,p_user,yr,p_key,p_day,seq+1,req,res,auth.uid());
 return res;
end $$;

create or replace function app.ph_import_2316(p_org uuid,p_user uuid,p_year integer,p_issuer text,p_hash text,p_from date,p_to date,p_fields jsonb,p_reference text)
returns uuid language plpgsql set search_path='' as $$
declare k text; v numeric; old app.ph_2316_import; out_id uuid;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_fields is null or jsonb_typeof(p_fields)<>'object' then raise exception 'form fields required' using errcode='22023'; end if;
 if (select count(*) from jsonb_object_keys(p_fields))<>14 then raise exception 'only supported numeric form fields allowed' using errcode='22023'; end if;
 foreach k in array array['19','20','21','22','23','24','25A','25B','26','27','28','34','38','52'] loop
  if jsonb_typeof(p_fields->k) is distinct from 'number' then raise exception 'missing form item %',k using errcode='22023'; end if;
  v:=(p_fields->>k)::numeric;
  if v<0 or v>1000000000 or v<>round(v,2) then raise exception 'invalid form item %',k using errcode='22023'; end if;
 end loop;
 if (p_fields->>'19')::numeric<>(p_fields->>'20')::numeric+(p_fields->>'21')::numeric
 or (p_fields->>'20')::numeric<>(p_fields->>'38')::numeric or (p_fields->>'21')::numeric<>(p_fields->>'52')::numeric
 or (p_fields->>'23')::numeric<>(p_fields->>'21')::numeric+(p_fields->>'22')::numeric
 or (p_fields->>'26')::numeric<>(p_fields->>'25A')::numeric+(p_fields->>'25B')::numeric
 or (p_fields->>'28')::numeric<>(p_fields->>'26')::numeric+(p_fields->>'27')::numeric
 or (p_fields->>'27')::numeric<>0 or (p_fields->>'34')::numeric>90000 or (p_fields->>'34')::numeric>(p_fields->>'20')::numeric
 then raise exception 'form totals inconsistent or unsupported PERA' using errcode='22023'; end if;
 -- Serialize import and approval; no duplicate source or overlapping approved periods.
  select * into old from app.ph_2316_import where organization_id=p_org and user_id=p_user and tax_year=p_year and document_sha256=p_hash;
 if found then
  if (old.issuer_ref,old.period_from,old.period_to,old.fields,old.evidence_reference) is distinct from (p_issuer,p_from,p_to,p_fields,p_reference)
  then raise exception 'document hash conflict' using errcode='22023'; end if;
  return old.id;
 end if;
 insert into app.ph_2316_import(organization_id,user_id,tax_year,issuer_ref,document_sha256,period_from,period_to,fields,evidence_reference,imported_by)
 values(p_org,p_user,p_year,p_issuer,p_hash,p_from,p_to,p_fields,p_reference,auth.uid()) returning id into out_id;
 return out_id;
end $$;

create or replace function app.ph_review_2316(p_org uuid,p_id uuid,p_approve boolean,p_reference text)
returns void language plpgsql set search_path='' as $$
declare i app.ph_2316_import; prev_taxable numeric; prev_withheld numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
  select * into i from app.ph_2316_import where organization_id=p_org and id=p_id;
 if not found or auth.uid() in (i.imported_by,i.user_id) then raise exception 'forbidden' using errcode='42501'; end if;
 if p_approve then
  if exists(select 1 from app.ph_2316_import x join app.ph_2316_review d on d.import_id=x.id and d.approved
  where x.organization_id=i.organization_id and x.user_id=i.user_id and x.tax_year=i.tax_year
  and (x.issuer_ref=i.issuer_ref or x.period_to>=i.period_from))
  then raise exception 'duplicate issuer, overlapping or out-of-order certificate' using errcode='22023'; end if;
  select coalesce(sum((x.fields->>'21')::numeric),0),coalesce(sum((x.fields->>'25A')::numeric),0)
  into prev_taxable,prev_withheld from app.ph_2316_import x join app.ph_2316_review d on d.import_id=x.id and d.approved
  where x.organization_id=i.organization_id and x.user_id=i.user_id and x.tax_year=i.tax_year;
  if ((i.fields->>'22')::numeric<>0 and (i.fields->>'22')::numeric<>prev_taxable)
   or ((i.fields->>'25B')::numeric<>0 and (i.fields->>'25B')::numeric<>prev_withheld)
  then raise exception 'previous-employer totals need reconciliation' using errcode='22023'; end if;
 end if;
 insert into app.ph_2316_review(import_id,approved,review_reference,reviewed_by) values(p_id,p_approve,p_reference,auth.uid());
end $$;

create or replace function app.ph_annual_from_verified_2316(p_org uuid,p_user uuid,p_rule_date date,p_final_pay_date date,p_reason text,
p_current_taxable numeric,p_current_withheld numeric,p_available numeric,p_current_start date,p_completeness_reference text)
returns jsonb language plpgsql stable set search_path='' as $$
declare tax_prior numeric; withheld_prior numeric; form_count bigint; yr int;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 if not exists(select 1 from public.memberships m where m.organization_id=p_org and m.user_id=p_user) then raise exception 'unknown employment identity' using errcode='42501'; end if;
 if p_current_start is null or not isfinite(p_current_start) or p_final_pay_date is null or p_current_start>p_final_pay_date
 then raise exception 'current employment dates required' using errcode='22023'; end if;
 yr:=extract(year from p_rule_date)::int;
 if exists(select 1 from app.ph_2316_import i left join app.ph_2316_review r on r.import_id=i.id
 where i.organization_id=p_org and i.user_id=p_user and i.tax_year=yr and (r.import_id is null or (r.approved and i.period_to>=p_current_start)))
 then raise exception 'pending or overlapping source certificate' using errcode='P0001'; end if;
 select coalesce(sum((i.fields->>'21')::numeric),0),coalesce(sum((i.fields->>'25A')::numeric),0),count(*)
 into tax_prior,withheld_prior,form_count from app.ph_2316_import i join app.ph_2316_review r on r.import_id=i.id and r.approved
 where i.organization_id=p_org and i.user_id=p_user and i.tax_year=yr;
 return app.ph_annual_adjustment(p_rule_date,p_final_pay_date,p_reason,p_current_taxable,tax_prior,p_current_withheld,withheld_prior,p_available,p_completeness_reference)
 ||jsonb_build_object('reviewedCertificates',form_count,'previousTaxable',tax_prior,'previousWithheld',withheld_prior);
end $$;

create or replace function app.accounting_decide_adjustment(p_id uuid,p_approve boolean,p_reason text)
returns void language plpgsql set search_path='' as $$
declare a app.accounting_adjustment_proposal; v_seconds numeric;
begin

  select * into a from app.accounting_adjustment_proposal where id=p_id;
  if not found then raise exception 'forbidden' using errcode='42501'; end if;
  perform app.accounting_tenant_lock(a.organization_id);
  if auth.uid() is null or auth.uid() in (a.proposed_by,a.user_id) or not app.has_permission(a.organization_id,'timesheet.adjust') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if p_approve then
    select coalesce(sum((l->>'seconds')::numeric),0) into v_seconds from app.accounting_locked_snapshot s
      cross join lateral jsonb_array_elements(s.reconciliation->'payLines') l
      where s.organization_id=a.organization_id and s.period_start=a.period_start and s.user_id=a.user_id and l->>'code'=a.pay_code;
    select v_seconds+coalesce(sum(p.delta_minutes::numeric*60),0) into v_seconds from app.accounting_adjustment_proposal p
      join app.accounting_adjustment_decision d on d.proposal_id=p.id and d.approved
      where p.organization_id=a.organization_id and p.period_start=a.period_start and p.user_id=a.user_id and p.pay_code=a.pay_code;
    if v_seconds+a.delta_minutes::numeric*60<0 then raise exception 'negative adjusted pay-code seconds balance' using errcode='P0001'; end if;
  end if;
  insert into app.accounting_adjustment_decision(proposal_id,approved,reason,decided_by) values(p_id,p_approve,p_reason,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(a.organization_id,auth.uid(),'accounting.adjustment_decided','adjustment',p_id::text,jsonb_build_object('approved',p_approve));
end $$;
