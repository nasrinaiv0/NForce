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
    'app.accounting_submission','app.accounting_locked_snapshot','app.ph_employment_history','app.ph_shift_history','app.ph_site_calendar_history','app.ph_workday_evidence','app.ph_workday_sources','app.ph_benefit_year','app.ph_benefit_event','app.ph_2316_import',
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
 organization_id uuid not null,user_id uuid not null,effective_on date not null,recorded_at timestamptz not null,
 ingested_by uuid not null references auth.users(id),ingested_at timestamptz not null default clock_timestamp(),
 foreign key(organization_id,user_id,effective_on,recorded_at) references app.ph_employment_history
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
-- Bind observed lifecycle to an explicitly reviewed canonical revision. Never derive
-- effective date, compensation or coverage from the observed membership alone.
create function app.ph_bind_lifecycle(p_org uuid,p_event bigint,p_effective date,p_recorded timestamptz)
returns void language plpgsql set search_path='' as $$
declare e app.accounting_lifecycle_event; h app.ph_employment_history; i app.accounting_lifecycle_ingestion;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'people.manage') or not app.has_permission(p_org,'schedule.manage') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into e from app.accounting_lifecycle_event where organization_id=p_org and id=p_event;
 if not found or e.user_id=auth.uid() then raise exception 'event unavailable' using errcode='42501'; end if;
 select * into i from app.accounting_lifecycle_ingestion where event_id=p_event;
 if found then
 if (i.effective_on,i.recorded_at) is distinct from (p_effective,p_recorded) then raise exception 'ingestion conflict' using errcode='22023'; end if;
 return;
 end if;
 select * into h from app.ph_employment_history where organization_id=p_org and user_id=e.user_id and effective_on=p_effective and recorded_at=p_recorded;
 if not found or (e.status='active' and h.status<>'employed') or (e.status='ended' and h.status<>'separated') or e.status not in ('active','ended')
 then raise exception 'reviewed canonical lifecycle revision required' using errcode='P0001'; end if;
 if exists(select 1 from app.accounting_lifecycle_event x where x.organization_id=p_org and x.user_id=e.user_id and x.id<e.id
 and not exists(select 1 from app.accounting_lifecycle_ingestion y where y.event_id=x.id)) then raise exception 'earlier lifecycle event unresolved' using errcode='P0001'; end if;
 insert into app.accounting_lifecycle_ingestion(event_id,organization_id,user_id,effective_on,recorded_at,ingested_by) values(p_event,p_org,e.user_id,p_effective,p_recorded,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.lifecycle_bound','membership',e.user_id::text,jsonb_build_object('eventId',p_event,'effectiveOn',p_effective));
end $$;
create function app.accounting_guard_locked_correction() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.source='correction' and exists(select 1 from public.payroll_periods p join app.accounting_period_manifest m on m.organization_id=p.organization_id and m.period_start=p.period_start
    where p.organization_id=new.organization_id and (new.occurred_at at time zone m.time_zone)::date between p.period_start and p.period_start+7) then raise exception 'locked accounting period: use audited adjustment' using errcode='42501'; end if;
  return new;
end $$;
create trigger p04_locked_correction before insert on public.attendance_events for each row execute function app.accounting_guard_locked_correction();
revoke all on function app.accounting_tenant_lock(uuid),app.accounting_write_barrier(),app.accounting_capture_lifecycle(),app.ph_bind_lifecycle(uuid,bigint,date,timestamptz),app.accounting_guard_locked_correction() from public,anon,authenticated,service_role;
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
  if not app.has_permission(p_org,'timesheet.submit',v_user) then raise exception 'forbidden' using errcode='42501'; end if;
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
  if not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
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


-- Separate preparer and approver for a departed employee; no login restoration.
create table app.accounting_departed_review (
  organization_id uuid not null,period_start date not null,user_id uuid not null,
  reconciliation jsonb not null,evidence_reference text not null check(length(btrim(evidence_reference)) between 1 and 250),
  prepared_by uuid not null references auth.users(id),prepared_at timestamptz not null default now(),
  primary key(organization_id,period_start,user_id),
  foreign key(organization_id,period_start) references app.accounting_period_manifest,
  foreign key(organization_id,user_id) references public.memberships(organization_id,user_id)
);
create table app.accounting_departed_decision (
  organization_id uuid not null,period_start date not null,user_id uuid not null,
  approved_by uuid not null references auth.users(id),approved_at timestamptz not null default now(),
  primary key(organization_id,period_start,user_id),
  foreign key(organization_id,period_start,user_id) references app.accounting_departed_review
);
do $$
declare n text;
begin
  foreach n in array array['accounting_departed_review','accounting_departed_decision'] loop
    execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
    execute format('alter table app.%I enable row level security',n);
    execute format('create trigger p04_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
  end loop;
end $$;
create function app.accounting_prepare_departed(p_org uuid,p_period date,p_user uuid,p_evidence text)
returns void language plpgsql set search_path='' as $$
declare r jsonb;
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
  if not exists(select 1 from public.memberships where organization_id=p_org and user_id=p_user and status='ended') then raise exception 'departed employee required' using errcode='P0001'; end if;
  if exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=p_period) then raise exception 'period already locked' using errcode='P0001'; end if;
  r:=app.accounting_reconcile(p_org,p_period,p_user);
  if r->>'classificationVersion' is distinct from '4' or (r->>'unapprovedOvertime')::int<>0 or (r->>'exactOvertimeReviewSeconds')::numeric>0 then raise exception 'classified reconciled hours required' using errcode='P0001'; end if;
  if exists(select 1 from public.timesheets where organization_id=p_org and period_start=p_period and user_id=p_user and status not in ('draft','returned')) then raise exception 'existing sheet requires review' using errcode='P0001'; end if;
  insert into app.accounting_departed_review(organization_id,period_start,user_id,reconciliation,evidence_reference,prepared_by)
    values(p_org,p_period,p_user,r,p_evidence,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.departed_prepared','membership',p_user::text,jsonb_build_object('periodStart',p_period));
end $$;
create function app.accounting_approve_departed(p_org uuid,p_period date,p_user uuid)
returns void language plpgsql set search_path='' as $$
declare a app.accounting_departed_review; r jsonb; sheet public.timesheets;
begin
  perform app.accounting_tenant_lock(p_org);
  if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
  select * into a from app.accounting_departed_review where organization_id=p_org and period_start=p_period and user_id=p_user;
  if not found or a.prepared_by=auth.uid() then raise exception 'independent review required' using errcode='42501'; end if;
  if not exists(select 1 from public.memberships where organization_id=p_org and user_id=p_user and status='ended') or exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=p_period) then raise exception 'employee or period changed' using errcode='P0001'; end if;
  r:=app.accounting_reconcile(p_org,p_period,p_user);
  if r is distinct from a.reconciliation then raise exception 'reconciliation changed' using errcode='P0001'; end if;
  insert into public.timesheets(organization_id,user_id,period_start) values(p_org,p_user,p_period) on conflict do nothing;
  select * into sheet from public.timesheets where organization_id=p_org and user_id=p_user and period_start=p_period for update;
  if sheet.status not in ('draft','returned') then raise exception 'existing sheet requires review' using errcode='P0001'; end if;
  update public.timesheets set status='approved',worked_minutes=(r->>'worked')::int,overtime_minutes=(r->>'overtime')::int,submitted_at=now(),decided_at=now() where id=sheet.id;
  insert into app.accounting_submission values(p_org,p_period,p_user,r,sheet.id) on conflict(organization_id,period_start,user_id) do update set reconciliation=excluded.reconciliation,sheet_id=excluded.sheet_id;
  insert into app.accounting_departed_decision(organization_id,period_start,user_id,approved_by) values(p_org,p_period,p_user,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.departed_approved','membership',p_user::text,jsonb_build_object('periodStart',p_period));
end $$;
revoke all on function app.accounting_prepare_departed(uuid,date,uuid,text),app.accounting_approve_departed(uuid,date,uuid) from public,anon,authenticated,service_role;
create or replace function app.accounting_propose_adjustment(p_org uuid,p_period date,p_user uuid,p_code text,p_delta int,
  p_reason text,p_evidence text,p_key text) returns uuid language plpgsql set search_path='' as $$
declare v_id uuid; v_old app.accounting_adjustment_proposal;
begin
  if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
  perform app.accounting_tenant_lock(p_org);
  if not app.has_permission(p_org,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
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
create or replace function app.accounting_decide_adjustment(p_id uuid,p_approve boolean,p_reason text)
returns void language plpgsql set search_path='' as $$
declare a app.accounting_adjustment_proposal; v_seconds numeric;
begin
  
  select * into a from app.accounting_adjustment_proposal where id=p_id;
  if not found or auth.uid() is null or auth.uid() in (a.proposed_by,a.user_id) or not app.has_permission(a.organization_id,'timesheet.adjust') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  perform app.accounting_tenant_lock(a.organization_id);
  if not app.has_permission(a.organization_id,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
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

create or replace function app.ph_materialize_week(p_org uuid,p_period date,p_reference text)
returns void language plpgsql set search_path='' as $$
declare d date;m public.memberships;h app.ph_employment_history;sh app.ph_shift_history;nsh app.ph_shift_history;
 c app.ph_site_calendar_history;nc app.ph_site_calendar_history;k text;nk text;known_at timestamptz;
begin
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'schedule.manage')
 then raise exception 'forbidden' using errcode='42501'; end if;
 if p_period is null or not isfinite(p_period) or extract(isodow from p_period)<>1
 then raise exception 'Monday required' using errcode='22023'; end if;
 if now() < ((p_period+7)::timestamp at time zone 'Asia/Manila')+interval '16 hours'
 then raise exception 'week not closed' using errcode='P0001'; end if;
 perform app.accounting_tenant_lock(p_org);
 if not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'schedule.manage') then raise exception 'forbidden' using errcode='42501'; end if;
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
