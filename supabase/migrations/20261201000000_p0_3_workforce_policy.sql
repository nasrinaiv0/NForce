
-- P0.3 private candidate. Existing public accounting release gates stay closed.
-- Historical sources are append-only; no current-state backfill is inferred.
create table app.accounting_employee_history (
  organization_id uuid not null,
  user_id uuid not null,
  effective_on date not null,
  eligible boolean not null,
  shift_start time not null,
  shift_end time not null,
  rest_days smallint[] not null,
  source_reference text not null check(length(btrim(source_reference)) between 1 and 250),
  recorded_by uuid not null references auth.users(id),
  recorded_at timestamptz not null default now(),
  primary key(organization_id,user_id,effective_on),
  foreign key(organization_id,user_id) references public.memberships(organization_id,user_id),
  check(shift_start<>shift_end),
  check(rest_days <@ array[1,2,3,4,5,6,7]::smallint[] and array_position(rest_days,null) is null)
);
create table app.accounting_policy_history (
  organization_id uuid not null references public.organizations(id),
  effective_on date not null,
  time_zone text not null,
  regular_minutes int not null check(regular_minutes between 1 and 960),
  minimum_ot_minutes int not null check(minimum_ot_minutes between 0 and 960),
  night_start int not null check(night_start between 0 and 1439),
  night_end int not null check(night_end between 0 and 1439),
  night_factor numeric(8,4) not null check(night_factor between 1 and 10),
  day_rates jsonb not null,
  overtime_factors jsonb not null,
  source_reference text not null check(length(btrim(source_reference)) between 1 and 250),
  recorded_by uuid not null references auth.users(id),
  recorded_at timestamptz not null default now(),
  primary key(organization_id,effective_on),
  check(night_start<>night_end)
);
create table app.accounting_calendar_history (
  organization_id uuid not null references public.organizations(id),
  work_date date not null,
  holiday_kind text not null check(holiday_kind in ('ordinary','special','regular')),
  source_reference text not null check(length(btrim(source_reference)) between 1 and 250),
  recorded_by uuid not null references auth.users(id),
  primary key(organization_id,work_date)
);
create table app.accounting_day_policy (
  organization_id uuid not null,
  period_start date not null,
  user_id uuid not null,
  work_date date not null,
  employee_effective_on date not null,
  policy_effective_on date not null,
  shift_start time not null,
  shift_end time not null,
  day_code text not null check(day_code in ('REG','RD','SH','SH_RD','RH','RH_RD')),
  day_rate numeric(8,4) not null,
  overtime_factor numeric(8,4) not null,
  night_start int not null,
  night_end int not null,
  night_factor numeric(8,4) not null,
  primary key(organization_id,period_start,user_id,work_date),
  foreign key(organization_id,period_start,user_id,work_date) references app.accounting_roster_day,
  foreign key(organization_id,user_id,employee_effective_on) references app.accounting_employee_history,
  foreign key(organization_id,policy_effective_on) references app.accounting_policy_history
);
create table app.accounting_adjustment_proposal (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  period_start date not null,
  user_id uuid not null,
  pay_code text not null check(pay_code ~ '^(REG|RD|SH|SH_RD|RH|RH_RD)(_OT)?(_ND)?$'),
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
-- Explicit privileges, RLS defense-in-depth, and immutable event history.
do $$
declare n text;
begin
  foreach n in array array['accounting_employee_history','accounting_policy_history','accounting_calendar_history',
    'accounting_day_policy','accounting_adjustment_proposal','accounting_adjustment_decision'] loop
    execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
    execute format('alter table app.%I enable row level security',n);
    execute format('create trigger p03_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
  end loop;
end $$;
-- Snapshot rows may only be appended while the manifest is unsealed.
create trigger p03_day_policy_guard before insert on app.accounting_day_policy
for each row execute function app.accounting_guard_roster();

-- Shared freeze barrier with materialization; never change a sealed period.
create function app.accounting_history_guard() returns trigger
language plpgsql set search_path='' as $$
declare v_date date;
begin
  -- Shared order: manifest, then history rows. Candidate writes are serialized.
  lock table app.accounting_period_manifest in share row exclusive mode;
  if tg_table_name='accounting_calendar_history' then v_date:=(to_jsonb(new)->>'work_date')::date;
  else v_date:=(to_jsonb(new)->>'effective_on')::date; end if;
  if exists(select 1 from app.accounting_period_manifest
    where organization_id=new.organization_id and sealed and v_date<period_start+7) then
    raise exception 'history intersects sealed accounting period; use audited adjustment' using errcode='42501';
  end if;
  return new;
end $$;
create trigger p03_employee_guard before insert on app.accounting_employee_history for each row execute function app.accounting_history_guard();
create trigger p03_policy_guard before insert on app.accounting_policy_history for each row execute function app.accounting_history_guard();
create trigger p03_calendar_guard before insert on app.accounting_calendar_history for each row execute function app.accounting_history_guard();

create function app.accounting_record_employee(p_org uuid,p_user uuid,p_effective date,p_eligible boolean,p_start time,p_end time,
  p_rest smallint[],p_reference text) returns void language plpgsql set search_path='' as $$
begin
  if auth.uid() is null or not app.has_permission(p_org,'people.manage',p_user) or not app.has_permission(p_org,'schedule.manage',p_user) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  lock table app.accounting_period_manifest in share row exclusive mode;
  insert into app.accounting_employee_history(organization_id,user_id,effective_on,eligible,shift_start,shift_end,rest_days,source_reference,recorded_by)
    values(p_org,p_user,p_effective,p_eligible,p_start,p_end,p_rest,p_reference,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.employee_history','membership',p_user::text,jsonb_build_object('effectiveOn',p_effective,'eligible',p_eligible));
end $$;

create function app.accounting_record_policy(p_org uuid,p_effective date,p_zone text,p_regular int,p_min_ot int,
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
  lock table app.accounting_period_manifest in share row exclusive mode;
  insert into app.accounting_policy_history(organization_id,effective_on,time_zone,regular_minutes,minimum_ot_minutes,night_start,night_end,night_factor,day_rates,overtime_factors,source_reference,recorded_by)
    values(p_org,p_effective,p_zone,p_regular,p_min_ot,p_night_start,p_night_end,p_night_factor,p_day_rates,p_ot_factors,p_reference,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.policy_history','policy',p_effective::text,'{}');
end $$;
create function app.accounting_record_calendar(p_org uuid,p_day date,p_kind text,p_reference text)
returns void language plpgsql set search_path='' as $$
begin
  if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
  lock table app.accounting_period_manifest in share row exclusive mode;
  insert into app.accounting_calendar_history values(p_org,p_day,p_kind,p_reference,auth.uid());
  insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
    values(p_org,auth.uid(),'accounting.calendar_history','calendar',p_day::text,jsonb_build_object('kind',p_kind));
end $$;

-- Materialize a week from explicit historical records. All memberships,
-- including ended and future joiners, require coverage for every date.
-- An authorized operator still attests completeness of the external source.
create function app.accounting_materialize_week(p_org uuid,p_period date,p_reference text)
returns void language plpgsql set search_path='' as $$
declare d date; m public.memberships; h app.accounting_employee_history; p app.accounting_policy_history;
  c app.accounting_calendar_history; z text; code text; rest boolean;
begin
  if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'schedule.manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if p_period is null or extract(isodow from p_period)<>1 then raise exception 'Monday required' using errcode='22023'; end if;
  -- Consistent with P0.2 locking order; membership write barrier is acquired first.
  lock table public.memberships in share mode;
  lock table app.accounting_period_manifest in share row exclusive mode;
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

-- Premium lines are derived from validated punch evidence, not input totals.
-- Per-minute elapsed UTC intervals make night classification DST-aware.
-- OT approval is consumed in chronological order, including night minutes.
create function app.accounting_classify(p_org uuid,p_period date,p_user uuid,r jsonb)
returns jsonb language sql stable set search_path='' as $$
with ev as (
  select ord, x->>'type' as kind,(x->>'at')::timestamptz as at_time
  from jsonb_array_elements(r->'events') with ordinality as t(x,ord)
), intervals as (
  select kind,at_time,lead(at_time) over(order by ord) as end_time,
    max(at_time) filter(where kind='clock_in') over(order by ord rows unbounded preceding) as clock_in
  from ev
), mins as (
  select (i.clock_in at time zone (r->>'timezone'))::date as work_date, g.at_time,
    row_number() over(partition by (i.clock_in at time zone (r->>'timezone'))::date order by g.at_time) as rn
  from intervals i cross join lateral generate_series(i.at_time,i.end_time-interval '1 minute',interval '1 minute') as g(at_time)
  where i.kind in ('clock_in','break_end') and i.end_time is not null
), rated as (
  select m.*,p.day_code,p.day_rate,p.overtime_factor,p.night_factor,p.night_start,p.night_end,
    d.regular_minutes,(j.x->>'overtime')::int as overtime,(j.x->>'approvedOvertime')::int as approved,
    (extract(hour from m.at_time at time zone (r->>'timezone'))::int*60+
      extract(minute from m.at_time at time zone (r->>'timezone'))::int) as local_minute
  from mins m join app.accounting_day_policy p on p.organization_id=p_org and p.period_start=p_period
    and p.user_id=p_user and p.work_date=m.work_date
  join app.accounting_roster_day d on d.organization_id=p.organization_id and d.period_start=p.period_start
    and d.user_id=p.user_id and d.work_date=p.work_date
  join lateral jsonb_array_elements(r->'days') as j(x) on (j.x->>'date')::date=m.work_date
), buckets as (
  select *,rn>regular_minutes as ot,
    case when night_start<night_end then local_minute>=night_start and local_minute<night_end
      else local_minute>=night_start or local_minute<night_end end as nd
  from rated where rn<=regular_minutes+least(overtime,approved)
), lines as (
  select work_date,day_code||case when ot then '_OT' else '' end||case when nd then '_ND' else '' end as code,
    round(day_rate*case when ot then overtime_factor else 1 end*case when nd then night_factor else 1 end,4) as multiplier,
    count(*)::int as minutes
  from buckets group by 1,2,3
)
select coalesce(jsonb_agg(jsonb_build_object('date',work_date,'code',code,'multiplier',multiplier,'minutes',minutes)
  order by work_date,code,multiplier),'[]'::jsonb) from lines
$$;
alter function app.accounting_reconcile(uuid,date,uuid) rename to accounting_reconcile_hours;
create function app.accounting_reconcile(p_org uuid,p_period date,p_user uuid)
returns jsonb language plpgsql stable set search_path='' as $$
declare r jsonb; lines jsonb; expected int; actual int;
begin
  r:=app.accounting_reconcile_hours(p_org,p_period,p_user);
  -- Legacy P0.2 fixtures remain private; do not label them as premium-classified.
  if not exists(select 1 from app.accounting_day_policy where organization_id=p_org and period_start=p_period) then return r; end if;
  if (select count(*) from app.accounting_day_policy where organization_id=p_org and period_start=p_period and user_id=p_user)
     <> jsonb_array_length(r->'days') then raise exception 'incomplete historical policy snapshot' using errcode='P0001'; end if;
  lines:=app.accounting_classify(p_org,p_period,p_user,r);
  select coalesce(sum((x->>'regular')::int+(x->>'approvedOvertime')::int),0) into expected from jsonb_array_elements(r->'days')x;
  select coalesce(sum((x->>'minutes')::int),0) into actual from jsonb_array_elements(lines)x;
  if actual<>expected then raise exception 'premium reconciliation mismatch' using errcode='P0001'; end if;
  return r||jsonb_build_object('payLines',lines,'classificationVersion',3);
end $$;

-- Post-lock corrections are independent, dual-control, append-only minute
-- deltas. They never mutate the locked hours or produce currency amounts.
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
    where s.organization_id=p_org and s.period_start=p_period and s.user_id=p_user and l->>'code'=p_code) then
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
declare a app.accounting_adjustment_proposal; v_minutes bigint;
begin
  lock table app.accounting_adjustment_proposal,app.accounting_adjustment_decision in share row exclusive mode;
  select * into a from app.accounting_adjustment_proposal where id=p_id;
  if not found or auth.uid() is null or auth.uid() in (a.proposed_by,a.user_id) or not app.has_permission(a.organization_id,'timesheet.adjust') then
    raise exception 'forbidden' using errcode='42501';
  end if;
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
revoke all on function app.accounting_history_guard(),app.accounting_record_employee(uuid,uuid,date,boolean,time,time,smallint[],text),
  app.accounting_record_policy(uuid,date,text,int,int,int,int,numeric,jsonb,jsonb,text),
  app.accounting_record_calendar(uuid,date,text,text),app.accounting_materialize_week(uuid,date,text),
  app.accounting_classify(uuid,date,uuid,jsonb),app.accounting_reconcile(uuid,date,uuid),
  app.accounting_propose_adjustment(uuid,date,uuid,text,int,text,text,text),app.accounting_decide_adjustment(uuid,boolean,text)
from public,anon,authenticated,service_role;
