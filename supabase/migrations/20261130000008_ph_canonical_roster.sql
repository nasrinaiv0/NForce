-- Canonical roster automation port of PR9. Employment eligibility exists only in
-- ph_employment_history; shift and calendar revisions contain independent facts.
create table app.ph_shift_history (
 organization_id uuid not null,user_id uuid not null,effective_on date not null check(isfinite(effective_on)),
 recorded_at timestamptz not null default clock_timestamp() check(isfinite(recorded_at)),
 start_local time not null,end_local time not null,rest_days smallint[] not null,
 source_reference text not null check(length(btrim(source_reference)) between 1 and 300),
 recorded_by uuid not null references auth.users(id),
 primary key(organization_id,user_id,effective_on,recorded_at),
 foreign key(organization_id,user_id) references public.memberships(organization_id,user_id),
 check(start_local<>end_local and start_local<time '24:00' and end_local<time '24:00'),
 check(rest_days <@ array[1,2,3,4,5,6,7]::smallint[] and array_position(rest_days,null) is null)
);
create table app.ph_site_calendar_history (
 organization_id uuid not null references public.organizations(id),
 site_reference text not null check(length(btrim(site_reference)) between 1 and 300),
 work_date date not null check(isfinite(work_date)),
 recorded_at timestamptz not null default clock_timestamp() check(isfinite(recorded_at)),
 holiday_kind text not null check(holiday_kind in ('ordinary','special','regular_holiday','double_regular')),
 source_reference text not null check(length(btrim(source_reference)) between 1 and 300),
 recorded_by uuid not null references auth.users(id),
 primary key(organization_id,site_reference,work_date,recorded_at)
);
create table app.ph_workday_sources (
 organization_id uuid not null,period_start date not null,user_id uuid not null,work_date date not null,
 shift_effective_on date not null,shift_recorded_at timestamptz not null,
 next_shift_effective_on date not null,next_shift_recorded_at timestamptz not null,
 site_reference text not null,calendar_recorded_at timestamptz not null,
 next_work_date date not null,next_calendar_recorded_at timestamptz not null,
 primary key(organization_id,period_start,user_id,work_date),
 foreign key(organization_id,period_start,user_id,work_date) references app.ph_workday_evidence,
 foreign key(organization_id,user_id,shift_effective_on,shift_recorded_at) references app.ph_shift_history,
 foreign key(organization_id,user_id,next_shift_effective_on,next_shift_recorded_at) references app.ph_shift_history,
 foreign key(organization_id,site_reference,work_date,calendar_recorded_at) references app.ph_site_calendar_history,
 foreign key(organization_id,site_reference,next_work_date,next_calendar_recorded_at) references app.ph_site_calendar_history,
 check(next_work_date=work_date+1)
);
do $$ declare n text; begin
 foreach n in array array['ph_shift_history','ph_site_calendar_history','ph_workday_sources'] loop
 execute format('alter table app.%I enable row level security',n);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger ph_roster_history_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
 end loop;
end $$;
create trigger ph_workday_sources_seal before insert on app.ph_workday_sources
for each row execute function app.accounting_guard_roster();

create function app.ph_record_shift(p_org uuid,p_user uuid,p_effective date,p_start time,p_end time,p_rest smallint[],p_reference text)
returns void language plpgsql set search_path='' as $$
begin
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'schedule.manage',p_user)
 then raise exception 'forbidden' using errcode='42501'; end if;
 insert into app.ph_shift_history(organization_id,user_id,effective_on,start_local,end_local,rest_days,source_reference,recorded_by)
 values(p_org,p_user,p_effective,p_start,p_end,p_rest,p_reference,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_shift_history','membership',p_user::text,jsonb_build_object('effectiveOn',p_effective));
end $$;
create function app.ph_record_site_calendar(p_org uuid,p_site text,p_day date,p_kind text,p_reference text)
returns void language plpgsql set search_path='' as $$
begin
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 insert into app.ph_site_calendar_history(organization_id,site_reference,work_date,holiday_kind,source_reference,recorded_by)
 values(p_org,p_site,p_day,p_kind,p_reference,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_calendar_history','calendar',p_day::text,jsonb_build_object('kind',p_kind));
end $$;
create function app.ph_day_kind(p_holiday text,p_rest boolean) returns text
language plpgsql immutable set search_path='' as $$
begin
 if p_rest is null or p_holiday is null or p_holiday not in ('ordinary','special','regular_holiday','double_regular')
 then raise exception 'unsupported calendar classification' using errcode='22023'; end if;
 return case when p_holiday='ordinary' then case when p_rest then 'rest' else 'ordinary' end
 when p_rest then case when p_holiday='double_regular' then 'double_regular_rest'
 when p_holiday='regular_holiday' then 'regular_holiday_rest' else 'special_rest' end
 else p_holiday end;
end $$;
-- Ordinary covered PH eight-hour policy only. Explicit non-employed history is
-- required for ineligible memberships; absence of history never means absence of work.
-- Snapshot exact shift/calendar revisions for both dates; later revisions do not
-- rewrite sealed snapshots. Unusual site/shift changes require independent review.
create function app.ph_materialize_week(p_org uuid,p_period date,p_reference text)
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
 lock table public.memberships in share mode;
 lock table app.accounting_period_manifest in share row exclusive mode;
 lock table app.ph_employment_history,app.ph_shift_history,app.ph_site_calendar_history in share mode;
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
revoke all on function app.ph_record_shift(uuid,uuid,date,time,time,smallint[],text),
 app.ph_record_site_calendar(uuid,text,date,text,text),app.ph_day_kind(text,boolean),
 app.ph_materialize_week(uuid,date,text) from public,anon,authenticated,service_role;
