-- Selective integration of PR9: reuse dual-control adjustment machinery; do not import
-- the duplicate employee model or rounded/approval-filtered premium classification.
-- Private candidate only, canonical eligibility/pay basis remains ph_employment_history.
create table app.ph_workday_evidence (
 organization_id uuid not null, period_start date not null, user_id uuid not null, work_date date not null,
 anchor_at timestamptz not null check(isfinite(anchor_at)),
 employment_effective_on date not null, employment_recorded_at timestamptz not null,
 calendar_classes jsonb not null check(jsonb_typeof(calendar_classes)='object'),
 source_reference text not null check(length(btrim(source_reference)) between 1 and 300),
 recorded_by uuid not null references auth.users(id),
 primary key(organization_id,period_start,user_id,work_date),
 foreign key(organization_id,period_start,user_id,work_date) references app.accounting_roster_day,
 foreign key(organization_id,user_id,employment_effective_on,employment_recorded_at)
 references app.ph_employment_history(organization_id,user_id,effective_on,recorded_at),
 check((anchor_at at time zone 'Asia/Manila')::date=work_date)
);
create table app.accounting_adjustment_proposal (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  period_start date not null,
  user_id uuid not null,
  pay_code text not null check(pay_code ~ '^(REG|RD|SH|SH_RD|RH|RH_RD|DH|DH_RD)(_OT)?(_ND)?$'),
  delta_minutes int not null check(delta_minutes between -10080 and 10080 and delta_minutes<>0),
  reason text not null check(length(btrim(reason)) between 10 and 500),
  evidence_reference text not null check(length(btrim(evidence_reference)) between 1 and 250),
  idempotency_key text not null check(length(idempotency_key) between 8 and 128),
  proposed_by uuid not null references auth.users(id),
  proposed_at timestamptz not null default now(),
  unique(organization_id,idempotency_key),
  foreign key(organization_id,period_start,user_id) references app.accounting_locked_snapshot
);
create table app.accounting_adjustment_decision (
  proposal_id uuid primary key references app.accounting_adjustment_proposal(id),
  approved boolean not null,
  reason text not null check(length(btrim(reason)) between 10 and 500),
  decided_by uuid not null references auth.users(id),
  decided_at timestamptz not null default now()
);

do $$ declare n text; begin
 foreach n in array array['ph_workday_evidence','accounting_adjustment_proposal','accounting_adjustment_decision'] loop
 execute format('alter table app.%I enable row level security',n);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger ph_integrated_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
 end loop;
end $$;
create trigger ph_workday_seal_guard before insert on app.ph_workday_evidence
for each row execute function app.accounting_guard_roster();

-- A trusted operator attests the workday anchor, dates and classifications; no inferred current state.
create function app.ph_record_workday(p_org uuid,p_period date,p_user uuid,p_day date,p_anchor timestamptz,p_calendar jsonb,p_reference text)
returns void language plpgsql set search_path='' as $$
declare h app.ph_employment_history; roster app.accounting_roster_day; manifest app.accounting_period_manifest; k text;
begin
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

-- The exact segmenter is authoritative for premium evidence. Old integer hours are
-- retained only for legacy review. Do not use them as monetary inputs.
create function app.ph_premium_factor(p_kind text,p_ot boolean,p_nd boolean)
returns numeric language plpgsql immutable set search_path='' as $$
declare f numeric;
begin
 f:=case p_kind when 'ordinary' then 1 when 'rest' then 1.3 when 'special' then 1.3 when 'special_rest' then 1.5
 when 'regular_holiday' then 2 when 'regular_holiday_rest' then 2.6 when 'double_regular' then 3 when 'double_regular_rest' then 3.9 else null end;
 if f is null or p_ot is null or p_nd is null then raise exception 'unsupported premium classification' using errcode='22023'; end if;
 return f*(case when p_ot then case when p_kind='ordinary' then 1.25 else 1.3 end else 1 end)*(case when p_nd then 1.1 else 1 end);
end $$;

alter function app.accounting_reconcile(uuid,date,uuid) rename to accounting_reconcile_hours;
create function app.accounting_reconcile(p_org uuid,p_period date,p_user uuid)
returns jsonb language plpgsql stable set search_path='' as $$
declare r jsonb; evidence app.ph_workday_evidence; intervals tstzrange[]; lines jsonb:='[]'; batch jsonb;
 exact_seconds numeric:=0; batch_seconds numeric; approved_seconds numeric; exact_ot numeric:=0; batch_ot numeric;
begin
 r:=app.accounting_reconcile_hours(p_org,p_period,p_user);
 if not exists(select 1 from app.ph_workday_evidence where organization_id=p_org and period_start=p_period) then
   return r; -- legacy private fixtures only; not a statutory payroll snapshot
 end if;
 if (select count(*) from app.ph_workday_evidence where organization_id=p_org and period_start=p_period and user_id=p_user)
 <>jsonb_array_length(r->'days') then raise exception 'incomplete PH workday attestation' using errcode='P0001'; end if;
 for evidence in select * from app.ph_workday_evidence where organization_id=p_org and period_start=p_period and user_id=p_user order by work_date loop
   with ev as (
     select ord,x->>'type' kind,(x->>'at')::timestamptz at_time
     from jsonb_array_elements(r->'events') with ordinality t(x,ord)
   ), spans as (
     select kind,at_time,lead(at_time) over(order by ord) end_time,
     max(at_time) filter(where kind='clock_in') over(order by ord rows unbounded preceding) clock_in from ev
   )
   select coalesce(array_agg(tstzrange(at_time,end_time,'[)') order by at_time),'{}'::tstzrange[]) into intervals
   from spans where kind in ('clock_in','break_end') and end_time is not null
   and (clock_in at time zone 'Asia/Manila')::date=evidence.work_date;
   with seg as (
     select s.*,case s.day_kind when 'ordinary' then 'REG' when 'rest' then 'RD' when 'special' then 'SH'
     when 'special_rest' then 'SH_RD' when 'regular_holiday' then 'RH' when 'regular_holiday_rest' then 'RH_RD'
     when 'double_regular' then 'DH' when 'double_regular_rest' then 'DH_RD' end
     ||case when s.overtime then '_OT' else '' end||case when s.night_shift then '_ND' else '' end code
     from app.ph_segment_workday(evidence.anchor_at,intervals,evidence.calendar_classes) s
   )
   select coalesce(jsonb_agg(jsonb_build_object('date',local_day,'workday',evidence.work_date,'code',code,
    'start',start_at,'end',end_at,'seconds',worked_seconds,'multiplier',app.ph_premium_factor(day_kind,overtime,night_shift))
    order by start_at),'[]'),coalesce(sum(worked_seconds),0),coalesce(sum(worked_seconds) filter(where overtime),0)
    into batch,batch_seconds,batch_ot from seg;
   lines:=lines||batch; exact_seconds:=exact_seconds+batch_seconds; exact_ot:=exact_ot+batch_ot;
 end loop;
 approved_seconds:=coalesce((r->>'approvedOvertime')::numeric,0)*60;
 -- Preserve all exact overtime, including unapproved/fractional; flag discrepancy
 -- and keep old approval gate conservative. Exact premium amounts not authorized.
 return r||jsonb_build_object('payLines',lines,'classificationVersion',4,'workedSeconds',exact_seconds,
 'overtimeSeconds',exact_ot,'exactOvertimeReviewSeconds',greatest(0,exact_ot-approved_seconds));
end $$;
create function app.accounting_propose_adjustment(p_org uuid,p_period date,p_user uuid,p_code text,p_delta int,
  p_reason text,p_evidence text,p_key text) returns uuid language plpgsql set search_path='' as $$
declare v_id uuid; v_old app.accounting_adjustment_proposal;
begin
  if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'timesheet.adjust') then raise exception 'forbidden' using errcode='42501'; end if;
  lock table app.accounting_adjustment_proposal in share row exclusive mode;
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
create function app.accounting_decide_adjustment(p_id uuid,p_approve boolean,p_reason text)
returns void language plpgsql set search_path='' as $$
declare a app.accounting_adjustment_proposal; v_seconds numeric;
begin
  lock table app.accounting_adjustment_proposal,app.accounting_adjustment_decision in share row exclusive mode;
  select * into a from app.accounting_adjustment_proposal where id=p_id;
  if not found or auth.uid() is null or auth.uid() in (a.proposed_by,a.user_id) or not app.has_permission(a.organization_id,'timesheet.adjust') then
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

revoke all on function app.ph_record_workday(uuid,date,uuid,date,timestamptz,jsonb,text),
app.ph_premium_factor(text,boolean,boolean),app.accounting_reconcile(uuid,date,uuid),
app.accounting_propose_adjustment(uuid,date,uuid,text,int,text,text,text),app.accounting_decide_adjustment(uuid,boolean,text)
from public,anon,authenticated,service_role;
