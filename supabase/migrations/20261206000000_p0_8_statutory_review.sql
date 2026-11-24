
-- P0.8 private, ordinary covered weekly taxable 2026 candidate through research cutoff.
-- No production activation, no payments, no public grants.
alter table app.ph_monetary_opening drop constraint ph_monetary_opening_tax_year_check;
alter table app.ph_monetary_opening add check(tax_year in (2025,2026));
alter table app.ph_monetary_snapshot add column exempt numeric(18,2) not null default 0 check(exempt>=0);
-- Replace original equation without depending on auto-generated constraint name.
do $$ declare c text; begin
 select conname into strict c from pg_constraint where conrelid='app.ph_monetary_snapshot'::regclass
 and contype='c' and pg_get_constraintdef(oid) like '%gross = (taxable + employee_contributions)%';
 execute format('alter table app.ph_monetary_snapshot drop constraint %I',c);
end $$;
alter table app.ph_monetary_snapshot add check(gross=taxable+employee_contributions+exempt and net=taxable+exempt-withholding);
create table app.ph_payroll_attestation (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null,user_id uuid not null,
 kind text not null check(kind in ('opening','month','divisor','week','annual')),
 scope_date date not null check(isfinite(scope_date) and extract(year from scope_date)=2026),
 payload jsonb not null check(jsonb_typeof(payload)='object' and octet_length(payload::text)<=32000),
 evidence text not null check(length(btrim(evidence)) between 8 and 300),
 maker uuid not null references auth.users(id),made_at timestamptz not null default clock_timestamp(),
 foreign key(organization_id,user_id) references public.memberships(organization_id,user_id),
 unique(organization_id,user_id,kind,scope_date),check(maker<>user_id)
);
create table app.ph_payroll_attestation_decision (
 attestation_id uuid primary key references app.ph_payroll_attestation,
 checker uuid not null references auth.users(id),evidence text not null check(length(btrim(evidence)) between 8 and 300),
 checked_at timestamptz not null default clock_timestamp()
);
create table app.ph_annual_settlement (
 organization_id uuid not null,user_id uuid not null,tax_year int not null check(tax_year=2026),
 final_period date not null, attestation_id uuid not null references app.ph_payroll_attestation,
 result jsonb not null, recorded_by uuid not null references auth.users(id),recorded_at timestamptz not null default now(),
 primary key(organization_id,user_id,tax_year),
 foreign key(organization_id,final_period,user_id) references app.ph_monetary_snapshot
);
do $$ declare n text; begin
 foreach n in array array['ph_payroll_attestation','ph_payroll_attestation_decision','ph_annual_settlement'] loop
 execute format('alter table app.%I enable row level security',n);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger p08_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
 end loop;
end $$;
create function app.ph_prepare_payroll_evidence(p_org uuid,p_user uuid,p_kind text,p_day date,p_payload jsonb,p_evidence text)
returns uuid language plpgsql set search_path='' as $$
declare v uuid;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 insert into app.ph_payroll_attestation(organization_id,user_id,kind,scope_date,payload,evidence,maker)
 values(p_org,p_user,p_kind,p_day,p_payload,p_evidence,auth.uid()) returning id into v;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_evidence_prepared','attestation',v::text,jsonb_build_object('kind',p_kind));
 return v;
end $$;
create function app.ph_approve_payroll_evidence(p_org uuid,p_id uuid,p_evidence text)
returns void language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; h app.ph_employment_history; y jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into a from app.ph_payroll_attestation where id=p_id and organization_id=p_org;
 if not found or auth.uid() in (a.maker,a.user_id) then raise exception 'independent checker required' using errcode='42501'; end if;
 y:=a.payload;
 case a.kind
 when 'opening' then
 if a.scope_date<>date '2026-01-01' or (y->>'method') is null or y->>'method' not in ('weekly','cumulative')
 or (y->>'previousPeriods')::int is null or (y->>'previousPeriods')::int not between 0 and 52
 or jsonb_typeof(y->'certificates') is distinct from 'array'
 or (y->>'currentStart')::date is null or extract(year from (y->>'currentStart')::date)<>2026
 or (y->>'firstPeriod')::date is null or (y->>'currentStart')::date>(y->>'firstPeriod')::date
 then raise exception 'invalid opening evidence' using errcode='22023'; end if;
 insert into app.ph_monetary_opening values(p_org,a.user_id,2026,(y->>'firstPeriod')::date,a.evidence,a.maker,auth.uid());
 when 'month' then
 insert into app.ph_monthly_basis_evidence values(p_org,a.user_id,a.scope_date,(y->>'sss')::numeric,(y->>'philhealth')::numeric,(y->>'pagibig')::numeric,(y->>'allocationPeriod')::date,a.evidence,a.maker,auth.uid());
 when 'divisor' then
 select * into h from app.ph_employment_history where organization_id=p_org and user_id=a.user_id
 and effective_on=a.scope_date and recorded_at=(y->>'recordedAt')::timestamptz and pay_basis='monthly';
 if not found then raise exception 'monthly employment revision required' using errcode='P0001'; end if;
 insert into app.ph_salary_divisor_evidence values(p_org,a.user_id,h.effective_on,h.recorded_at,(y->>'annualPaidDays')::numeric,a.evidence,a.maker,auth.uid());
 when 'week' then
 if extract(isodow from a.scope_date)<>1 or jsonb_typeof(y->'nonwork') is distinct from 'array'
 or jsonb_array_length(y->'nonwork')>7 or jsonb_typeof(y->'supplemental') is distinct from 'array'
 or jsonb_array_length(y->'supplemental')>50 or y->>'coverage' is distinct from 'ordinary-rank-and-file-taxable-complete'
 then raise exception 'invalid weekly coverage' using errcode='22023'; end if;
 when 'annual' then
 if y->>'reason' is null or y->>'reason' not in ('year_end','termination') or (y->>'available')::numeric is null
 or (y->>'available')::numeric<0 or (y->>'available')::numeric<>round((y->>'available')::numeric,2)
 then raise exception 'invalid annual evidence' using errcode='22023'; end if;
 end case;
 insert into app.ph_payroll_attestation_decision values(a.id,auth.uid(),p_evidence,clock_timestamp());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_evidence_approved','attestation',a.id::text,jsonb_build_object('kind',a.kind));
end $$;
create function app.ph_approved_evidence(p_org uuid,p_user uuid,p_kind text,p_day date)
returns app.ph_payroll_attestation language plpgsql stable set search_path='' as $$
declare a app.ph_payroll_attestation;
begin
 select x.* into a from app.ph_payroll_attestation x join app.ph_payroll_attestation_decision d on d.attestation_id=x.id
 where x.organization_id=p_org and x.user_id=p_user and x.kind=p_kind and x.scope_date=p_day;
 if not found then raise exception 'approved evidence missing: %',p_kind using errcode='P0001'; end if; return a;
end $$;
-- Exact reviewed certificate set, including original-document custody review.
-- Period counts remain independently attested, never inferred from dates.
create function app.ph_prior_employer_2026(p_org uuid,p_user uuid) returns jsonb
language plpgsql stable set search_path='' as $$
declare a app.ph_payroll_attestation; ids jsonb; taxable numeric; withheld numeric; n int; ct int;
begin
 a:=app.ph_approved_evidence(p_org,p_user,'opening','2026-01-01');
 if exists(select 1 from app.ph_2316_import i left join app.ph_2316_review r on r.import_id=i.id
 left join app.ph_2316_custody c on c.import_id=i.id left join app.ph_2316_custody_review cr on cr.import_id=i.id
 where i.organization_id=p_org and i.user_id=p_user and i.tax_year=2026
 and (r.import_id is null or (r.approved and (c.import_id is null or cr.import_id is null or i.period_to>=(a.payload->>'currentStart')::date))))
 then raise exception 'pending custody or overlapping employment' using errcode='P0001'; end if;
 select coalesce(jsonb_agg(i.id::text order by i.id),'[]'),coalesce(sum((i.fields->>'21')::numeric),0),coalesce(sum((i.fields->>'25A')::numeric),0),count(*)::int
 into ids,taxable,withheld,ct from app.ph_2316_import i join app.ph_2316_review r on r.import_id=i.id and r.approved
 where i.organization_id=p_org and i.user_id=p_user and i.tax_year=2026;
 n:=(a.payload->>'previousPeriods')::int;
 if ids is distinct from a.payload->'certificates' or (ct=0 and n<>0) or (ct>0 and (n<=0 or a.payload->>'method'<>'cumulative'))
 then raise exception 'prior certificate set or period count mismatch' using errcode='P0001'; end if;
 return jsonb_build_object('taxable',taxable,'withheld',withheld,'periods',n,'certificates',ids,'method',a.payload->>'method');
end $$;
-- Prevent late benefits changing an immutable weekly snapshot.
create function app.ph_guard_posted_benefit() returns trigger language plpgsql set search_path='' as $$
begin
 perform app.accounting_tenant_lock(new.organization_id);
 if exists(select 1 from app.ph_monetary_snapshot s where s.organization_id=new.organization_id and s.user_id=new.user_id
 and new.paid_on between s.period_start and s.pay_date) then raise exception 'posted benefit requires correction workflow' using errcode='42501'; end if;
 return new;
end $$;
create trigger p08_posted_benefit before insert on app.ph_benefit_event for each row execute function app.ph_guard_posted_benefit();
-- Private ciphertext retrieval only after dual review, current tenant authorization and audit.
create function app.ph_get_reviewed_envelope(p_org uuid,p_import uuid) returns jsonb
language plpgsql set search_path='' as $$
declare c app.ph_2316_custody;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select x.* into c from app.ph_2316_custody x join app.ph_2316_custody_review cr on cr.import_id=x.import_id
 join app.ph_2316_review r on r.import_id=x.import_id and r.approved
 where x.organization_id=p_org and x.import_id=p_import and x.user_id<>auth.uid();
 if not found then raise exception 'reviewed envelope unavailable' using errcode='42501'; end if;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_envelope_retrieved','certificate',p_import::text,'{}');
 return jsonb_build_object('ciphertext',encode(c.ciphertext,'base64'),'sha256',c.ciphertext_sha256,'plaintextSha256',c.plaintext_sha256,'keyReference',c.key_reference);
end $$;

-- Private arithmetic candidates only. Inputs are distinct, independently classified monthly agency bases.
-- No eligibility, deduction allocation, remittance or public execution.
create or replace function app.ph_contribution_candidate(p_agency text,p_basis numeric,p_month date)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare msc numeric; reg numeric; mpf numeric; ec numeric; ee numeric; er numeric; premium numeric; basis numeric;
begin
  if p_agency is null or p_basis is null or p_basis::text in ('NaN','Infinity','-Infinity')
     or p_basis<=0 or p_basis>1000000000 or p_basis<>round(p_basis,2)
     or p_month is null or p_month < date '2024-02-01' or p_month > date '2026-11-01'
     or extract(day from p_month)<>1 then
    raise exception 'unsupported contribution basis or month' using errcode='22023';
  end if;
  case p_agency
  when 'sss' then
    if p_month < date '2025-01-01' then
      raise exception 'unsupported SSS schedule' using errcode='22023';
    end if;
    -- Equivalent to the published 61 compensation brackets, not a percentage of gross salary.
    msc:=greatest(5000,least(35000,floor((p_basis+250)/500)*500));
    reg:=least(msc,20000); mpf:=msc-reg;
    ec:=case when msc>=15000 then 30 else 10 end;
    ee:=msc*0.05; er:=msc*0.10+ec;
    return jsonb_build_object('msc',msc,'employee',ee,'employer',er,'total',ee+er,
      'employeeRegular',reg*0.05,'employeeMpf',mpf*0.05,
      'employerRegular',reg*0.10,'employerMpf',mpf*0.10,'employerEc',ec);
  when 'philhealth' then
    if p_month < date '2025-01-01' or p_month > date '2026-11-01' then
      raise exception 'PhilHealth schedule requires independent year confirmation' using errcode='22023';
    end if;
    basis:=greatest(10000,least(100000,p_basis));
    premium:=round(basis*0.05,2);
    ee:=trunc(premium/2,2); er:=premium-ee;
    return jsonb_build_object('basis',basis,'employee',ee,'employer',er,'total',premium);
  when 'pagibig' then
    basis:=least(10000,p_basis);
    ee:=round(basis*case when p_basis<=1500 then 0.01 else 0.02 end,2);
    er:=round(basis*0.02,2);
    return jsonb_build_object('basis',basis,'employee',ee,'employer',er,'total',ee+er);
  else
    raise exception 'unsupported contribution agency' using errcode='22023';
  end case;
end $$;
revoke all on function app.ph_contribution_candidate(text,numeric,date) from public,anon,authenticated,service_role;
comment on function app.ph_contribution_candidate(text,numeric,date) is
'Unapproved private PH monthly contribution arithmetic for ordinary covered employees. SSS 2024-006, PhilHealth 2025-0002 and PIA 2026 rate confirmation, HDMF 460. Classified bases, eligibility and rounding require independent review.';

create function app.ph_post_monetary_week_2026(p_org uuid,p_period date,p_user uuid)
returns jsonb language plpgsql set search_path='' as $$
declare s app.accounting_locked_snapshot; o app.ph_monetary_opening; m app.ph_monthly_basis_evidence;
 h app.ph_employment_history; dv app.ph_salary_divisor_evidence; l jsonb;
 line_amount numeric; raw_gross numeric:=0; gross numeric; hourly numeric;
 ee numeric:=0; er numeric:=0; tax numeric; net numeric; taxable numeric;
 prev_taxable numeric; prev_tax numeric; n int; last_period date; pd date:=p_period+6; mon date;
 a app.ph_payroll_attestation; opening app.ph_payroll_attestation; prior jsonb; b app.ph_benefit_event; exempt numeric:=0; d date; minutes numeric; seen date[]:='{}'; ev_day app.ph_workday_evidence;
 contrib jsonb:='{}'; j jsonb; agency text; basis numeric; v jsonb; lines jsonb:='[]'; journal jsonb; total numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_period is null or extract(isodow from p_period)<>1 or extract(year from pd)<>2026 or extract(year from p_period)<>2026 or pd>date '2026-11-24' then raise exception 'unsupported monetary period' using errcode='22023'; end if;
 if exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and period_start=p_period and user_id=p_user) then raise exception 'monetary snapshot already posted' using errcode='P0001'; end if;
 select * into s from app.accounting_locked_snapshot where organization_id=p_org and period_start=p_period and user_id=p_user;
 if not found or s.reconciliation->>'classificationVersion' is distinct from '4' or (s.reconciliation->>'exactOvertimeReviewSeconds')::numeric<>0 then raise exception 'locked exact reconciled PH attendance required' using errcode='P0001'; end if;
 if exists(select 1 from app.accounting_adjustment_proposal where organization_id=p_org and period_start=p_period and user_id=p_user) then raise exception 'adjusted payroll requires settlement review' using errcode='P0001'; end if;
 select * into o from app.ph_monetary_opening where organization_id=p_org and user_id=p_user and tax_year=2026;
 if not found then raise exception 'reviewed zero opening and coverage required' using errcode='P0001'; end if;
 opening:=app.ph_approved_evidence(p_org,p_user,'opening','2026-01-01');
 a:=app.ph_approved_evidence(p_org,p_user,'week',p_period);
 prior:=app.ph_prior_employer_2026(p_org,p_user);
 if exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'annual settlement already recorded' using errcode='P0001'; end if;
 if not exists(select 1 from app.ph_benefit_year where organization_id=p_org and user_id=p_user and tax_year=2026 and opening_through<p_period)
 then raise exception 'reviewed benefit opening required' using errcode='P0001'; end if;
 select count(*)::int,coalesce(sum(x.taxable),0),coalesce(sum(x.withholding),0),max(x.period_start)
 into n,prev_taxable,prev_tax,last_period from app.ph_monetary_snapshot x where organization_id=p_org and user_id=p_user and extract(year from x.pay_date)=2026;
 if (n=0 and p_period<>o.first_period) or (n>0 and p_period<>last_period+7) then raise exception 'noncontiguous payroll history' using errcode='P0001'; end if;
 if exists(select 1 from app.ph_benefit_event b2 where b2.organization_id=p_org and b2.user_id=p_user and b2.tax_year=2026 and b2.paid_on<p_period and not exists(select 1 from app.ph_monetary_snapshot x where x.organization_id=p_org and x.user_id=p_user and b2.paid_on between x.period_start and x.pay_date)) then raise exception 'unreconciled earlier benefit' using errcode='P0001'; end if;
 for l in select value from jsonb_array_elements(s.reconciliation->'payLines') loop
 select eh.* into h from app.ph_workday_evidence e join app.ph_employment_history eh on (eh.organization_id,eh.user_id,eh.effective_on,eh.recorded_at)=(e.organization_id,e.user_id,e.employment_effective_on,e.employment_recorded_at)
 where e.organization_id=p_org and e.period_start=p_period and e.user_id=p_user and e.work_date=(l->>'workday')::date;
 if not found or h.status<>'employed' then raise exception 'historical pay evidence missing' using errcode='P0001'; end if;
 if h.pay_basis='hourly' then hourly:=h.rate_php;
 elsif h.pay_basis='daily' then hourly:=h.rate_php/8;
 elsif h.pay_basis='monthly' then
 perform app.ph_approved_evidence(p_org,p_user,'divisor',h.effective_on);
 select * into dv from app.ph_salary_divisor_evidence where (organization_id,user_id,effective_on,recorded_at)=(h.organization_id,h.user_id,h.effective_on,h.recorded_at);
 if not found then raise exception 'reviewed salary divisor missing' using errcode='P0001'; end if;
 hourly:=h.rate_php*12/dv.annual_paid_days/8;
 else raise exception 'unsupported basis' using errcode='22023'; end if;
 line_amount:=hourly*(l->>'seconds')::numeric/3600*(l->>'multiplier')::numeric;
 raw_gross:=raw_gross+line_amount;
 lines:=lines||jsonb_build_array(l||jsonb_build_object('hourlyRate',hourly,'unroundedAmount',line_amount,'employmentRevision',h.recorded_at));
 end loop;
 -- Paid nonwork: only independently attested zero-work dates in the sealed roster.
 for l in select value from jsonb_array_elements(a.payload->'nonwork') loop
 d:=(l->>'date')::date; minutes:=(l->>'minutes')::numeric;
 if d is null or d not between p_period and pd or d=any(seen) or minutes is null or minutes<=0 or minutes>480 or minutes<>trunc(minutes)
 or l->>'kind' is null or l->>'kind' not in ('paid_leave','paid_regular_holiday') or length(btrim(coalesce(l->>'reference','')))<8
 or exists(select 1 from jsonb_array_elements(s.reconciliation->'payLines') x where (x->>'date')::date=d or (x->>'workday')::date=d)
 then raise exception 'invalid or overlapping paid nonwork' using errcode='22023'; end if;
 select * into ev_day from app.ph_workday_evidence where organization_id=p_org and user_id=p_user and period_start=p_period and work_date=d;
 if not found or (l->>'kind'='paid_regular_holiday' and ev_day.calendar_classes->>d::text not in ('regular_holiday','regular_holiday_rest')) then raise exception 'nonwork calendar evidence missing' using errcode='P0001'; end if;
 select * into h from app.ph_employment_history where (organization_id,user_id,effective_on,recorded_at)=(ev_day.organization_id,ev_day.user_id,ev_day.employment_effective_on,ev_day.employment_recorded_at);
 if h.pay_basis='hourly' then hourly:=h.rate_php; elsif h.pay_basis='daily' then hourly:=h.rate_php/8; else raise exception 'paid nonwork salary basis requires separate review' using errcode='P0001'; end if;
 line_amount:=hourly*minutes/60; raw_gross:=raw_gross+line_amount; seen:=array_append(seen,d);
 lines:=lines||jsonb_build_array(l||jsonb_build_object('unroundedAmount',line_amount,'employmentRevision',h.recorded_at));
 end loop;
 for l in select value from jsonb_array_elements(a.payload->'supplemental') loop
 line_amount:=(l->>'amount')::numeric;
 if l->>'code' is null or l->>'code' not in ('commission','taxable_allowance','other_taxable') or line_amount is null or line_amount<0 or line_amount>1000000000 or line_amount<>round(line_amount,2) or length(btrim(coalesce(l->>'reference','')))<8 then raise exception 'invalid supplemental evidence' using errcode='22023'; end if;
 raw_gross:=raw_gross+line_amount;lines:=lines||jsonb_build_array(l);
 end loop;
 gross:=round(raw_gross,2);
 for b in select * from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=2026 and paid_on between p_period and pd order by sequence_no loop
 gross:=gross+(b.result->>'gross')::numeric;
 exempt:=exempt+(b.result->>'gross')::numeric-(b.result->>'taxable')::numeric;
 lines:=lines||jsonb_build_array(jsonb_build_object('benefitEvent',b.event_key,'result',b.result));
 end loop;
 mon:=date_trunc('month',pd::timestamp)::date;
 select * into m from app.ph_monthly_basis_evidence where organization_id=p_org and user_id=p_user and month_start=mon;
 if not found then raise exception 'reviewed monthly agency bases missing' using errcode='P0001'; end if;
 perform app.ph_approved_evidence(p_org,p_user,'month',mon);
 if p_period>m.allocation_period and not exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=m.allocation_period) then raise exception 'missing monthly allocation' using errcode='P0001'; end if;
 if p_period=m.allocation_period then
 foreach agency in array array['sss','philhealth','pagibig'] loop
 basis:=case agency when 'sss' then m.sss_basis when 'philhealth' then m.philhealth_basis else m.pagibig_basis end;
 v:=app.ph_contribution_candidate(agency,basis,mon);
 ee:=ee+(v->>'employee')::numeric;er:=er+(v->>'employer')::numeric;
 contrib:=contrib||jsonb_build_object(agency,v);
 end loop;
 end if;
 if gross-exempt<ee then raise exception 'insufficient compensation for contribution allocation' using errcode='P0001'; end if;
 taxable:=gross-exempt-ee;
 if prior->>'method'='cumulative' then
 j:=app.ph_cumulative_withholding(prev_taxable+taxable+(prior->>'taxable')::numeric,n+1+(prior->>'periods')::int,prev_tax+(prior->>'withheld')::numeric,'weekly',pd);
 else
 j:=jsonb_build_object('withhold',app.ph_tax_candidate(taxable,'weekly',pd),'method','weekly');
 end if;
 tax:=(j->>'withhold')::numeric;
 if tax>taxable then raise exception 'insufficient compensation for withholding' using errcode='P0001'; end if;
 net:=taxable+exempt-tax;
 total:=gross+er;
 journal:=jsonb_build_array(jsonb_build_object('account','wage_expense','debit',gross,'credit',0),
 jsonb_build_object('account','employer_contribution_expense','debit',er,'credit',0),
 jsonb_build_object('account','employee_contribution_payable','debit',0,'credit',ee),
 jsonb_build_object('account','employer_contribution_payable','debit',0,'credit',er),
 jsonb_build_object('account','withholding_payable','debit',0,'credit',tax),
 jsonb_build_object('account','net_payable','debit',0,'credit',net));
 if (select sum((x->>'debit')::numeric) from jsonb_array_elements(journal)x)<>total
 or (select sum((x->>'credit')::numeric) from jsonb_array_elements(journal)x)<>total then raise exception 'unbalanced payroll' using errcode='P0001'; end if;
 v:=jsonb_build_object('earnings',lines,'contributions',contrib,'cumulative',j,'openingEvidence',o.evidence,'basisEvidence',m.evidence,'method','ph-weekly-2026-reviewed-candidate','prior',prior,'attestation',a.id,'exempt',exempt);
 insert into app.ph_monetary_snapshot(organization_id,period_start,user_id,pay_date,gross,employee_contributions,employer_contributions,taxable,withholding,net,evidence,posted_by,exempt)
 values(p_org,p_period,p_user,pd,gross,ee,er,taxable,tax,net,v,auth.uid(),exempt);
 insert into app.ph_payroll_journal values(p_org,p_period,p_user,journal,total,total);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_monetary_snapshot','membership',p_user::text,jsonb_build_object('periodStart',p_period));
 return jsonb_build_object('gross',gross,'exempt',exempt,'employeeContributions',ee,'employerContributions',er,'taxable',taxable,'withholding',tax,'net',net,'journalTotal',total);
end $$;

create function app.ph_record_annual_settlement_2026(p_org uuid,p_user uuid,p_final_period date)
returns jsonb language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; prior jsonb; s app.ph_monetary_snapshot; taxable numeric; withheld numeric; j jsonb; avail numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 a:=app.ph_approved_evidence(p_org,p_user,'annual',p_final_period);
 prior:=app.ph_prior_employer_2026(p_org,p_user);
 select * into s from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_final_period;
 if not found or s.pay_date>date '2026-11-24' or exists(select 1 from app.ph_monetary_snapshot x where x.organization_id=p_org and x.user_id=p_user and x.period_start>p_final_period) then raise exception 'final period incomplete' using errcode='P0001'; end if;
 if a.payload->>'reason'='termination' and not exists(select 1 from public.memberships where organization_id=p_org and user_id=p_user and status='ended') then raise exception 'termination evidence missing' using errcode='P0001'; end if;
 if exists(select 1 from app.ph_benefit_event b where b.organization_id=p_org and b.user_id=p_user and b.tax_year=2026 and not exists(select 1 from app.ph_monetary_snapshot x where x.organization_id=p_org and x.user_id=p_user and b.paid_on between x.period_start and x.pay_date)) then raise exception 'unreconciled benefit event' using errcode='P0001'; end if;
 avail:=(a.payload->>'available')::numeric;
 if avail>s.net then raise exception 'available final compensation exceeds snapshot' using errcode='22023'; end if;
 select sum(x.taxable),sum(x.withholding) into taxable,withheld from app.ph_monetary_snapshot x where x.organization_id=p_org and x.user_id=p_user and extract(year from x.pay_date)=2026;
 j:=app.ph_annual_adjustment(s.pay_date,s.pay_date,a.payload->>'reason',taxable,(prior->>'taxable')::numeric,withheld,(prior->>'withheld')::numeric,avail,a.evidence);
 insert into app.ph_annual_settlement(organization_id,user_id,tax_year,final_period,attestation_id,result,recorded_by)
 values(p_org,p_user,2026,p_final_period,a.id,j,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_annual_settlement_candidate','membership',p_user::text,jsonb_build_object('period',p_final_period));
 return j;
end $$;
revoke all on function app.ph_prepare_payroll_evidence(uuid,uuid,text,date,jsonb,text),app.ph_approve_payroll_evidence(uuid,uuid,text),
 app.ph_approved_evidence(uuid,uuid,text,date),app.ph_prior_employer_2026(uuid,uuid),app.ph_guard_posted_benefit(),
 app.ph_get_reviewed_envelope(uuid,uuid),app.ph_post_monetary_week_2026(uuid,date,uuid),app.ph_record_annual_settlement_2026(uuid,uuid,date)
 from public,anon,authenticated,service_role;
