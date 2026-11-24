
-- P1.3: single immutable canonical ledger, weekly replay reuses weekly calculator.
do $$ declare c text;begin
 select conname into strict c from pg_constraint where conrelid='app.ph_monetary_snapshot'::regclass and contype='c' and pg_get_constraintdef(oid) like '%revision = 1%frequency%';
 execute format('alter table app.ph_monetary_snapshot drop constraint %I',c);
end $$;
alter table app.ph_payroll_attestation drop constraint ph_payroll_attestation_kind_check;
alter table app.ph_payroll_attestation add check(kind in ('opening','month','divisor','week','annual','salary_month','settlement_journal','custody_policy','statutory_quote','cutoff_opening','period','wage','contribution','reversal','entitlement','replay','cutoff_final','weekly_replay','form1601c'));

create or replace function app.ph_approve_payroll_evidence(p_org uuid,p_id uuid,p_evidence text)
returns void language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; h app.ph_employment_history; y jsonb; v numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into a from app.ph_payroll_attestation where id=p_id and organization_id=p_org;
 if not found or auth.uid() in (a.maker,a.user_id) then raise exception 'independent checker required' using errcode='42501'; end if;
 y:=a.payload;
 case a.kind
 when 'wage' then
 if y->>'region' is null or y->>'region' not in ('NCR','CAR','I','II','III','IV-A','IV-B','V','VI','VII','VIII','IX','X','XI','XII','XIII','NIR','BARMM')
 or length(btrim(coalesce(y->>'locality','')))<2 or length(btrim(coalesce(y->>'sector','')))<2 or length(btrim(coalesce(y->>'coverage','')))<8
 or length(btrim(coalesce(y->>'site','')))<1 or length(btrim(coalesce(y->>'order','')))<1
 or coalesce(y->>'source','') !~ '^https://(nwpc[.]dole[.]gov[.]ph|mole[.]bangsamoro[.]gov[.]ph)/'
 or coalesce(y->>'documentSha256','') !~ '^[a-f0-9]{64}$'
 or (y->>'through')::date is null or (y->>'through')::date<a.scope_date or (y->>'through')::date>date '2026-11-24'
 or not app.ph_stat_money((y->>'dailyMinimum')::numeric) or (y->>'dailyMinimum')::numeric<=0
 then raise exception 'complete reviewed wage-order category and source required' using errcode='22023';end if;
 when 'cutoff_opening' then
 if a.scope_date<>date '2026-01-01' or y->>'frequency' is null or y->>'frequency' not in ('daily','semi-monthly','monthly')
 or (y->>'firstPeriod')::date is null or (y->>'firstPeriod')::date not between date '2026-01-06' and date '2026-11-24'
 or (y->>'currentStart')::date is distinct from (y->>'firstPeriod')::date
 or jsonb_typeof(y->'certificates') is distinct from 'array'
 or (y->>'previousPeriods')::integer is null or (y->>'previousPeriods')::integer<0
 or jsonb_typeof(y->'benefitOpening') is distinct from 'object'
 or y->>'completeCurrentYtd' is distinct from 'true'
 then raise exception 'complete reviewed opening required' using errcode='22023';end if;
 when 'period','replay' then
 if (y->>'end')::date is null or (y->>'end')::date<a.scope_date or (y->>'end')::date>date '2026-11-24'
 or y->>'frequency' is null or y->>'frequency' not in ('daily','semi-monthly','monthly')
 or y->>'coverage' is distinct from 'ordinary-covered-complete'
 or jsonb_typeof(y->'nonwork') is distinct from 'object'
 or jsonb_typeof(y->'benefitKeys') is distinct from 'array'
 or y->>'cumulative' is null or y->>'cumulative' not in ('true','false')
 or not app.ph_stat_money((y->>'taxDeductible')::numeric)
 or not app.ph_stat_money((y->>'taxableExtras')::numeric)
 or not app.ph_stat_money((y->>'hazardPay')::numeric)
 or ((y->>'hazardPay')::numeric>0 and length(btrim(coalesce(y->>'hazardEvidence','')))<8)
 then raise exception 'complete reviewed period evidence required' using errcode='22023';end if;
 if a.kind='replay' and (y->>'undispatched' is distinct from 'true' or length(btrim(coalesce(y->>'reason','')))<8 or (y->>'originalAttestation')::uuid is null) then raise exception 'reviewed replacement evidence required' using errcode='22023';end if;
 when 'cutoff_final' then
 if y->>'reason' is distinct from 'termination' or y->>'exitKind' is distinct from 'ordinary_resignation_no_severance' or y->>'undispatched' is distinct from 'true' or y->>'completeExitEntitlements' is distinct from 'true' or y->>'rankAndFileEligible' is distinct from 'true' or not app.ph_stat_money((y->>'available')::numeric) then raise exception 'restricted reviewed final compensation required' using errcode='22023';end if;
 when 'contribution' then
 if extract(day from a.scope_date)<>1 or (y->>'allocationDate')::date is null or date_trunc('month',(y->>'allocationDate')::date)::date<>a.scope_date
 then raise exception 'monthly contribution allocation date required' using errcode='22023';end if;
 foreach v in array array[(y->>'sss')::numeric,(y->>'philhealth')::numeric,(y->>'pagibig')::numeric] loop
 if not app.ph_stat_money(v) or v<=0 then raise exception 'reviewed agency bases required' using errcode='22023';end if;end loop;
 when 'reversal' then
 if y->>'undispatched' is distinct from 'true' or length(btrim(coalesce(y->>'reason','')))<8 then raise exception 'reviewed undispatched reversal required' using errcode='22023'; end if;
 when 'entitlement' then
 if (y->>'quoteDate')::date is null or y->>'category' is distinct from 'thirteenth' or (y->>'payDate')::date is distinct from a.scope_date then raise exception 'reviewed thirteenth entitlement required' using errcode='22023'; end if;
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
 when 'week','weekly_replay' then
 if extract(isodow from a.scope_date)<>1 or jsonb_typeof(y->'nonwork') is distinct from 'array'
 or jsonb_array_length(y->'nonwork')>7 or jsonb_typeof(y->'supplemental') is distinct from 'array'
 or jsonb_array_length(y->'supplemental')>50 or y->>'coverage' is distinct from 'ordinary-rank-and-file-taxable-complete'
 then raise exception 'invalid weekly coverage' using errcode='22023'; end if;
 if a.kind='weekly_replay' and (y->>'undispatched' is distinct from 'true' or length(btrim(coalesce(y->>'reason','')))<8 or (y->>'originalAttestation')::uuid is null) then raise exception 'reviewed weekly replacement required' using errcode='22023';end if;
 when 'form1601c' then
 if extract(day from a.scope_date)<>1 or y->>'version' is distinct from '1601-C-2018-ENCS' or jsonb_typeof(y->'items') is distinct from 'object' or y->>'paidCompensationVerified' is distinct from 'true' then raise exception 'reviewed form evidence required' using errcode='22023';end if;
 when 'salary_month' then
 if extract(day from a.scope_date)<>1 or y->>'method' is distinct from 'full-calendar-month-no-unpaid-days' or (y->>'recordedAt')::timestamptz is null or (y->>'effectiveOn')::date is null then raise exception 'invalid salary coverage' using errcode='22023'; end if;
 when 'settlement_journal' then
 if y->>'treatment' is distinct from 'reviewed-recoverable-and-payable-accrual' or jsonb_typeof(y->'result') is distinct from 'object' then raise exception 'invalid settlement evidence' using errcode='22023'; end if;
 when 'custody_policy' then
 if (y->>'importId')::uuid is null or (y->>'retainUntil')::date is null or not isfinite((y->>'retainUntil')::date) or jsonb_typeof(y->'legalHold') is distinct from 'boolean' then raise exception 'invalid custody policy' using errcode='22023'; end if;
 when 'statutory_quote' then
 if y->>'category' is null or y->>'category' not in ('thirteenth','maternity','leave','special_women','separation','retirement') or jsonb_typeof(y->'eligible') is distinct from 'boolean' or (y->>'eligible')::boolean is distinct from true then raise exception 'reviewed eligibility required' using errcode='22023'; end if;
 when 'annual' then
 if y->>'reason' is null or y->>'reason' not in ('year_end','termination') or (y->>'available')::numeric is null
 or (y->>'available')::numeric<0 or (y->>'available')::numeric<>round((y->>'available')::numeric,2)
 then raise exception 'invalid annual evidence' using errcode='22023'; end if;
 end case;
 insert into app.ph_payroll_attestation_decision values(a.id,auth.uid(),p_evidence,clock_timestamp());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_evidence_approved','attestation',a.id::text,jsonb_build_object('kind',a.kind));
end $$;
create or replace function app.ph_guard_period_overlap() returns trigger language plpgsql set search_path='' as $$
declare o app.ph_monetary_snapshot;a app.ph_payroll_attestation;
begin
 perform app.accounting_tenant_lock(new.organization_id);
 if exists(select 1 from app.ph_annual_settlement x where x.organization_id=new.organization_id and x.user_id=new.user_id and x.tax_year=extract(year from new.pay_date)) then raise exception 'closed year' using errcode='P0001';end if;
 if new.revision=2 then
 select * into o from app.ph_monetary_snapshot where (organization_id,period_start,user_id,revision)=(new.organization_id,new.period_start,new.user_id,1);
 if not found or (o.frequency,o.pay_date) is distinct from (new.frequency,new.pay_date)
 or not exists(select 1 from app.ph_canonical_reversal r where (r.organization_id,r.period_start,r.user_id)=(new.organization_id,new.period_start,new.user_id))
 or exists(select 1 from app.ph_monetary_snapshot x where x.organization_id=new.organization_id and x.user_id=new.user_id and x.period_start>new.period_start)
 then raise exception 'latest reversed original required' using errcode='P0001';end if;
 a:=app.ph_approved_evidence(new.organization_id,new.user_id,case when new.frequency='weekly' then 'weekly_replay' else 'replay' end,new.period_start);
 if new.evidence->>'attestation' is distinct from a.id::text or a.payload->>'originalAttestation' is distinct from o.evidence->>'attestation' then raise exception 'replacement evidence mismatch' using errcode='P0001';end if;
 elsif app.ph_unresolved_reversal(new.organization_id,new.user_id) then raise exception 'reversed period requires controlled replay' using errcode='P0001';end if;
 if exists(select 1 from app.ph_monetary_snapshot s where s.organization_id=new.organization_id and s.user_id=new.user_id and extract(year from s.pay_date)=extract(year from new.pay_date)
 and (s.frequency<>new.frequency or (s.period_start<=new.pay_date and s.pay_date>=new.period_start))
 and not (new.revision=2 and s.revision=1 and s.period_start=new.period_start)) then raise exception 'overlapping payroll or frequency change' using errcode='P0001';end if;
 return new;
end $$;
create function app.ph_post_week_version(p_org uuid,p_period date,p_user uuid,p_replay boolean)
returns jsonb language plpgsql set search_path='' as $$
declare original app.ph_monetary_snapshot; existing app.ph_monetary_snapshot; version_no int; s app.accounting_locked_snapshot; o app.ph_monetary_opening; m app.ph_monthly_basis_evidence;
 h app.ph_employment_history; dv app.ph_salary_divisor_evidence; l jsonb;
 line_amount numeric; raw_gross numeric:=0; gross numeric; hourly numeric;
 ee numeric:=0; er numeric:=0; tax numeric; net numeric; taxable numeric;
 prev_taxable numeric; prev_tax numeric; n int; last_period date; pd date:=p_period+6; mon date;
 a app.ph_payroll_attestation; opening app.ph_payroll_attestation; prior jsonb; b app.ph_benefit_event; exempt numeric:=0; d date; minutes numeric; seen date[]:='{}'; ev_day app.ph_workday_evidence;
 salary_mode boolean:=false; salary_days int; known_at timestamptz; base_amount numeric; factor numeric; allocation app.ph_paid_leave_allocation; used numeric; req numeric;
 contrib jsonb:='{}'; j jsonb; agency text; basis numeric; v jsonb; lines jsonb:='[]'; journal jsonb; total numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_period is null or extract(isodow from p_period)<>1 or extract(year from pd)<>2026 or extract(year from p_period)<>2026 or pd>date '2026-11-24' then raise exception 'unsupported monetary period' using errcode='22023'; end if;

 if p_replay is null then raise exception 'posting mode required' using errcode='22023';end if;
 version_no:=case when p_replay then 2 else 1 end;
 if p_replay then
 a:=app.ph_approved_evidence(p_org,p_user,'weekly_replay',p_period);
 if a.maker=auth.uid() then raise exception 'replay maker denied' using errcode='42501';end if;
 select * into original from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_period and revision=1;
 if not found or original.frequency<>'weekly' or a.payload->>'originalAttestation' is distinct from original.evidence->>'attestation'
 or not exists(select 1 from app.ph_canonical_reversal where organization_id=p_org and user_id=p_user and period_start=p_period)
 or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start>p_period)
 or exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026)
 or exists(select 1 from app.ph_month_report where organization_id=p_org and month_start=date_trunc('month',pd)::date)
 then raise exception 'latest unreported reversed week required' using errcode='P0001';end if;
 if (a.payload-array['reason','undispatched','originalAttestation','supplemental']) is distinct from ((app.ph_approved_evidence(p_org,p_user,'week',p_period)).payload-'supplemental') then raise exception 'only supplemental correction supported' using errcode='P0001';end if;
 select * into existing from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_period and revision=2;
 if found then
 if existing.evidence->>'attestation' is distinct from a.id::text then raise exception 'replacement conflict' using errcode='P0001';end if;
 return jsonb_build_object('gross',existing.gross,'net',existing.net,'revision',2);end if;
 else
 if app.ph_unresolved_reversal(p_org,p_user) or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and period_start=p_period and user_id=p_user) then raise exception 'monetary snapshot already posted or unresolved reversal' using errcode='P0001';end if;
 end if;
 select * into s from app.accounting_locked_snapshot where organization_id=p_org and period_start=p_period and user_id=p_user;
 if not found or s.reconciliation->>'classificationVersion' is distinct from '4' or (s.reconciliation->>'exactOvertimeReviewSeconds')::numeric<>0 then raise exception 'locked exact reconciled PH attendance required' using errcode='P0001'; end if;
 if exists(select 1 from app.accounting_adjustment_proposal where organization_id=p_org and period_start=p_period and user_id=p_user) then raise exception 'adjusted payroll requires settlement review' using errcode='P0001'; end if;
 select * into o from app.ph_monetary_opening where organization_id=p_org and user_id=p_user and tax_year=2026;
 if not found then raise exception 'reviewed zero opening and coverage required' using errcode='P0001'; end if;
 opening:=app.ph_approved_evidence(p_org,p_user,'opening','2026-01-01');
 a:=app.ph_approved_evidence(p_org,p_user,case when p_replay then 'weekly_replay' else 'week' end,p_period);
 prior:=app.ph_prior_employer_2026(p_org,p_user);
 if exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'annual settlement already recorded' using errcode='P0001'; end if;
 if not exists(select 1 from app.ph_benefit_year where organization_id=p_org and user_id=p_user and tax_year=2026 and opening_through<p_period)
 then raise exception 'reviewed benefit opening required' using errcode='P0001'; end if;
 select count(*)::int,coalesce(sum(x.taxable),0),coalesce(sum(x.withholding),0),max(x.period_start)
 into n,prev_taxable,prev_tax,last_period from app.ph_effective_monetary x where organization_id=p_org and user_id=p_user and extract(year from x.pay_date)=2026 and x.period_start<p_period;
 if (n=0 and p_period<>o.first_period) or (n>0 and p_period<>last_period+7) then raise exception 'noncontiguous payroll history' using errcode='P0001'; end if;
 if exists(select 1 from app.ph_benefit_event b2 where b2.organization_id=p_org and b2.user_id=p_user and b2.tax_year=2026 and b2.paid_on<p_period and not exists(select 1 from app.ph_effective_monetary x where x.organization_id=p_org and x.user_id=p_user and b2.paid_on between x.period_start and x.pay_date)) then raise exception 'unreconciled earlier benefit' using errcode='P0001'; end if;
 select locked_at into known_at from public.payroll_periods where organization_id=p_org and period_start=p_period;
 select count(*) into salary_days from generate_series(p_period,pd,interval '1 day') g where exists(select 1 from app.ph_workday_evidence e2 join app.ph_employment_history eh on (eh.organization_id,eh.user_id,eh.effective_on,eh.recorded_at)=(e2.organization_id,e2.user_id,e2.employment_effective_on,e2.employment_recorded_at) where e2.organization_id=p_org and e2.user_id=p_user and e2.period_start=p_period and e2.work_date=g::date and eh.pay_basis='monthly');
 if salary_days>0 then
 if salary_days<>7 then raise exception 'monthly salary requires seven attested days' using errcode='P0001'; end if;
 salary_mode:=true;
 for d in select generate_series(p_period,pd,interval '1 day')::date loop
 h:=app.ph_reviewed_month_salary(p_org,p_user,d,known_at);
 if not exists(select 1 from app.ph_workday_evidence e2 where e2.organization_id=p_org and e2.user_id=p_user and e2.period_start=p_period and e2.work_date=d and e2.employment_effective_on=h.effective_on and e2.employment_recorded_at=h.recorded_at) then raise exception 'sealed salary revision mismatch' using errcode='P0001'; end if;
 base_amount:=app.ph_salary_calendar_allocation(h.rate_php,d);
 raw_gross:=raw_gross+base_amount;lines:=lines||jsonb_build_array(jsonb_build_object('date',d,'code','guaranteed_salary','amount',base_amount,'employmentRevision',h.recorded_at));
 end loop;
 end if;
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
 factor:=(l->>'multiplier')::numeric;
 if h.pay_basis='monthly' then
 if not salary_mode then raise exception 'reviewed guaranteed salary coverage required' using errcode='P0001'; end if;
 if (l->>'code') not like '%_OT%' then factor:=factor-1; end if;
 end if;
 line_amount:=hourly*(l->>'seconds')::numeric/3600*factor;
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
 if not found or (l->>'kind'='paid_regular_holiday' and coalesce(ev_day.calendar_classes->>d::text,'') not in ('regular_holiday','regular_holiday_rest')) then raise exception 'nonwork calendar evidence missing' using errcode='P0001'; end if;
 select * into h from app.ph_employment_history where (organization_id,user_id,effective_on,recorded_at)=(ev_day.organization_id,ev_day.user_id,ev_day.employment_effective_on,ev_day.employment_recorded_at);
 if l->>'kind'='paid_leave' then
 select * into allocation from app.ph_paid_leave_allocation where organization_id=p_org and user_id=p_user and period_start=p_period and work_date=d;
 if not found or allocation.minutes<>minutes or allocation.request_id is distinct from (l->>'requestId')::uuid then raise exception 'approved paid leave allocation required' using errcode='P0001'; end if;
 select -days*480 into req from public.leave_transactions where request_id=allocation.request_id and organization_id=p_org and user_id=p_user and kind='usage';
 select sum(x.minutes) into used from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.request_id=allocation.request_id;
 if req is null or used is distinct from req then raise exception 'incomplete approved leave allocation' using errcode='P0001'; end if;
 end if;
 if h.pay_basis='hourly' then hourly:=h.rate_php; line_amount:=hourly*minutes/60;
 elsif h.pay_basis='daily' then hourly:=h.rate_php/8; line_amount:=hourly*minutes/60;
 elsif h.pay_basis='monthly' and salary_mode then line_amount:=0;
 else raise exception 'paid nonwork salary basis requires separate review' using errcode='P0001'; end if; raw_gross:=raw_gross+line_amount; seen:=array_append(seen,d);
 lines:=lines||jsonb_build_array(l||jsonb_build_object('unroundedAmount',line_amount,'employmentRevision',h.recorded_at));
 end loop;
 if exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.period_start=p_period and not(x.work_date=any(seen))) then raise exception 'unreconciled paid leave day' using errcode='P0001'; end if;
 if exists(select 1 from public.approval_requests q where q.organization_id=p_org and q.requester_id=p_user and q.kind='leave' and q.status='approved'
 and (q.payload->>'start')::date<=pd and (q.payload->>'end')::date>=p_period
 and not exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.period_start=p_period and x.request_id=q.id))
 then raise exception 'approved leave requires classified allocation' using errcode='P0001'; end if;
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
 if p_period>m.allocation_period and not exists(select 1 from app.ph_effective_monetary where organization_id=p_org and user_id=p_user and period_start=m.allocation_period) then raise exception 'missing monthly allocation' using errcode='P0001'; end if;
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
 jsonb_build_object('account','sss_payable','debit',0,'credit',coalesce((contrib->'sss'->>'total')::numeric,0)),
 jsonb_build_object('account','philhealth_payable','debit',0,'credit',coalesce((contrib->'philhealth'->>'total')::numeric,0)),
 jsonb_build_object('account','pagibig_payable','debit',0,'credit',coalesce((contrib->'pagibig'->>'total')::numeric,0)),
 jsonb_build_object('account','withholding_payable','debit',0,'credit',tax),
 jsonb_build_object('account','net_payable','debit',0,'credit',net));
 if (select sum((x->>'debit')::numeric) from jsonb_array_elements(journal)x)<>total
 or (select sum((x->>'credit')::numeric) from jsonb_array_elements(journal)x)<>total then raise exception 'unbalanced payroll' using errcode='P0001'; end if;
 v:=jsonb_build_object('earnings',lines,'contributions',contrib,'cumulative',j,'openingEvidence',o.evidence,'basisEvidence',m.evidence,'method','ph-weekly-2026-reviewed-candidate','prior',prior,'attestation',a.id,'exempt',exempt);
 insert into app.ph_monetary_snapshot(organization_id,period_start,user_id,pay_date,gross,employee_contributions,employer_contributions,taxable,withholding,net,evidence,posted_by,exempt,revision)
 values(p_org,p_period,p_user,pd,gross,ee,er,taxable,tax,net,v,auth.uid(),exempt,version_no);
 insert into app.ph_payroll_journal values(p_org,p_period,p_user,journal,total,total,version_no);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),case when p_replay then 'accounting.ph_week_replayed' else 'accounting.ph_monetary_snapshot' end,'membership',p_user::text,jsonb_build_object('periodStart',p_period));
 return jsonb_build_object('gross',gross,'exempt',exempt,'employeeContributions',ee,'employerContributions',er,'taxable',taxable,'withholding',tax,'net',net,'journalTotal',total,'revision',version_no);
end $$;
create or replace function app.ph_record_annual_settlement_2026(p_org uuid,p_user uuid,p_final_period date)
returns jsonb language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; prior jsonb; s app.ph_monetary_snapshot; taxable numeric; withheld numeric; j jsonb; avail numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 if app.ph_unresolved_reversal(p_org,p_user) then raise exception 'unresolved reversal' using errcode='P0001';end if;
 if exists(select 1 from app.ph_effective_monetary where organization_id=p_org and user_id=p_user and frequency<>'weekly') then return app.ph_record_cutoff_final(p_org,p_user,p_final_period);end if;

 a:=app.ph_approved_evidence(p_org,p_user,'annual',p_final_period);
 prior:=app.ph_prior_employer_2026(p_org,p_user);
 select * into s from app.ph_effective_monetary where organization_id=p_org and user_id=p_user and period_start=p_final_period;
 if not found or s.pay_date>date '2026-11-24' or exists(select 1 from app.ph_effective_monetary x where x.organization_id=p_org and x.user_id=p_user and x.period_start>p_final_period) then raise exception 'final period incomplete' using errcode='P0001'; end if;
 if a.payload->>'reason'='termination' and not exists(select 1 from public.memberships where organization_id=p_org and user_id=p_user and status='ended') then raise exception 'termination evidence missing' using errcode='P0001'; end if;
 if exists(select 1 from app.ph_benefit_event b where b.organization_id=p_org and b.user_id=p_user and b.tax_year=2026 and not exists(select 1 from app.ph_effective_monetary x where x.organization_id=p_org and x.user_id=p_user and b.paid_on between x.period_start and x.pay_date)) then raise exception 'unreconciled benefit event' using errcode='P0001'; end if;
 avail:=(a.payload->>'available')::numeric;
 if avail>s.net then raise exception 'available final compensation exceeds snapshot' using errcode='22023'; end if;
 select sum(x.taxable),sum(x.withholding) into taxable,withheld from app.ph_effective_monetary x where x.organization_id=p_org and x.user_id=p_user and extract(year from x.pay_date)=2026;
 j:=app.ph_annual_adjustment(s.pay_date,s.pay_date,a.payload->>'reason',taxable,(prior->>'taxable')::numeric,withheld,(prior->>'withheld')::numeric,avail,a.evidence);
 insert into app.ph_annual_settlement(organization_id,user_id,tax_year,final_period,attestation_id,result,recorded_by,final_revision)
 values(p_org,p_user,2026,p_final_period,a.id,j,auth.uid(),s.revision);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_annual_settlement_candidate','membership',p_user::text,jsonb_build_object('period',p_final_period));
 return j;
end $$;

create or replace function app.ph_post_monetary_week_2026(p_org uuid,p_period date,p_user uuid) returns jsonb language sql set search_path='' as $$select app.ph_post_week_version(p_org,p_period,p_user,false)$$;
create function app.ph_replay_week_2026(p_org uuid,p_user uuid,p_period date) returns jsonb language sql set search_path='' as $$select app.ph_post_week_version(p_org,p_period,p_user,true)$$;

-- Form 1601-C Jan 2018 ENCS Part II items 14–25: restricted preparation
-- validator, not filing. Classification requires reviewed evidence and actual
-- compensation payment verification; no inference from accrual alone.
create function app.ph_validate_1601c_items(p_items jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare k text; v numeric; non_tax numeric;
begin
 if jsonb_typeof(p_items) is distinct from 'object' or (select count(*) from jsonb_object_keys(p_items))<>12 then raise exception 'exact items 14 through 25 required' using errcode='22023';end if;
 foreach k in array array['14','15','16','17','18','19','20','21','22','23','24','25'] loop
 if jsonb_typeof(p_items->k) is distinct from 'number' then raise exception 'numeric form item required: %',k using errcode='22023';end if;
 v:=(p_items->>k)::numeric;
 if v<0 or v>9999999999999999.99 or v<>round(v,2) then raise exception 'invalid money item: %',k using errcode='22023';end if;
 end loop;
 select sum((p_items->>i::text)::numeric) into non_tax from generate_series(15,20)i;
 if non_tax<>(p_items->>'21')::numeric or (p_items->>'14')::numeric-non_tax<>(p_items->>'22')::numeric
 or (p_items->>'22')::numeric-(p_items->>'23')::numeric<>(p_items->>'24')::numeric
 or (p_items->>'25')::numeric>(p_items->>'24')::numeric then raise exception 'form computation does not reconcile' using errcode='22023';end if;
 return p_items;
end $$;
create function app.ph_reviewed_1601c_worksheet(p_org uuid,p_user uuid,p_month date) returns jsonb
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;r app.ph_month_report;i jsonb;g numeric;t numeric;ded numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501';end if;
 a:=app.ph_approved_evidence(p_org,p_user,'form1601c',p_month);
 select x.* into r from app.ph_month_report x join app.ph_month_report_review y using(organization_id,month_start) where x.organization_id=p_org and x.month_start=p_month;
 if not found or r.totals is distinct from app.ph_month_report_totals(p_org,p_month)
 or a.payload->'sourcePeriods' is distinct from r.source_periods then raise exception 'reviewed current report required' using errcode='P0001';end if;
 -- Exclude annual adjustments; Schedule I/II and refund reporting require separate mapping.
 if exists(select 1 from app.ph_annual_settlement x join app.ph_effective_monetary s on (s.organization_id,s.period_start,s.user_id,s.revision)=(x.organization_id,x.final_period,x.user_id,x.final_revision) where x.organization_id=p_org and s.pay_date>=p_month and s.pay_date<(p_month+interval '1 month')::date) then raise exception 'annual adjustment worksheet not supported' using errcode='P0001';end if;
 i:=app.ph_validate_1601c_items(a.payload->'items');
 select sum(s.gross),sum(s.taxable),sum(coalesce(s.tax_deductible,s.employee_contributions)) into g,t,ded from app.ph_effective_monetary s where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<(p_month+interval '1 month')::date;
 if g is distinct from (i->>'14')::numeric or t is distinct from (i->>'22')::numeric or ded is distinct from (i->>'19')::numeric or (r.totals->>'bir')::numeric is distinct from (i->>'25')::numeric then raise exception 'form items differ from canonical ledger' using errcode='P0001';end if;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.ph_1601c_worksheet','month',p_month::text,jsonb_build_object('version','1601-C-2018-ENCS'));
 return jsonb_build_object('form','1601-C','version','January 2018 ENCS','officialFiling',false,'items',i,'attestation',a.id);
end $$;
revoke all on function app.ph_post_week_version(uuid,date,uuid,boolean),app.ph_replay_week_2026(uuid,uuid,date),app.ph_validate_1601c_items(jsonb),app.ph_reviewed_1601c_worksheet(uuid,uuid,date) from public,anon,authenticated,service_role;


-- Extend the existing frequency check, not the ledger or engine.
do $$ declare c text;begin
 select conname into strict c from pg_constraint where conrelid='app.ph_monetary_snapshot'::regclass and contype='c' and pg_get_constraintdef(oid) like '%frequency%tax_deductible%';
 execute format('alter table app.ph_monetary_snapshot drop constraint %I',c);
end $$;
alter table app.ph_monetary_snapshot add check((frequency='weekly' and pay_date=period_start+6 and tax_deductible is null) or
 (frequency in ('daily','semi-monthly','monthly') and period_start>=date '2026-01-06' and pay_date<=date '2026-11-24' and pay_date=app.ph_period_end(period_start,frequency) and tax_deductible is not null));

create or replace function app.ph_post_cutoff_version(p_org uuid,p_user uuid,p_start date,p_replay boolean)
returns jsonb language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;o app.ph_payroll_attestation;wa app.ph_payroll_attestation;ca app.ph_payroll_attestation;
 h app.ph_employment_history; dv app.ph_salary_divisor_evidence; reviewed app.ph_employment_history; first_h app.ph_employment_history;ev app.ph_workday_evidence;z app.accounting_locked_snapshot;
 old app.ph_monetary_snapshot;y app.ph_benefit_year;b app.ph_benefit_event;original app.ph_monetary_snapshot; version_no int;
 freq text;e date;d date;wk date;mon date;alloc date;line jsonb;code text;nonwork jsonb;actual_ids jsonb;
 worked numeric;secs numeric;rate numeric;factor numeric;amount numeric;wage numeric;is_mwe boolean;any_mwe boolean:=false;any_non_mwe boolean:=false;
 basic numeric:=0;premium numeric:=0;qualifying numeric:=0;raw_basic numeric:=0;raw_premium numeric:=0;raw_exempt numeric:=0;
 extra numeric;hazard numeric;bg numeric:=0;be numeric:=0;gross numeric;exempt numeric;taxable numeric;ded numeric;ee numeric:=0;er numeric:=0;wt numeric;
 prior jsonb;pt numeric;pw numeric;n int;last_end date;sticky boolean;use_average boolean;avg_result jsonb;
 s jsonb;ph jsonb;f jsonb;contrib jsonb;calc jsonb;lines jsonb:='[]';bal numeric;regtax numeric;supptax numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 if p_start is null or p_start not between date '2026-01-06' and date '2026-11-24' then raise exception 'unsupported payroll date' using errcode='22023';end if;

 if p_replay is null then raise exception 'posting mode required' using errcode='22023';end if;
 version_no:=case when p_replay then 2 else 1 end;
 a:=app.ph_approved_evidence(p_org,p_user,case when p_replay then 'replay' else 'period' end,p_start);
 if a.maker=auth.uid() then raise exception 'maker cannot post' using errcode='42501';end if;
 if exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'closed payroll' using errcode='P0001';end if;
 if p_replay then
 select * into original from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_start and revision=1;
 if not found or original.frequency not in ('daily','semi-monthly','monthly') or a.payload->>'originalAttestation' is distinct from original.evidence->>'attestation'
 or not exists(select 1 from app.ph_canonical_reversal where organization_id=p_org and user_id=p_user and period_start=p_start)
 or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start>p_start)
 then raise exception 'latest reversed original required' using errcode='P0001';end if;
 if (a.payload - array['reason','undispatched','originalAttestation','taxableExtras']) is distinct from ((app.ph_approved_evidence(p_org,p_user,'period',p_start)).payload - 'taxableExtras') then raise exception 'unsupported replacement scope' using errcode='P0001';end if;
 else
 if app.ph_unresolved_reversal(p_org,p_user) or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_start and revision=2) then raise exception 'reversed or replaced cutoff' using errcode='P0001';end if;
 end if;
 select * into old from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_start and revision=version_no;
 if found then
 if old.evidence->>'attestation' is distinct from a.id::text then raise exception 'posting conflict' using errcode='P0001';end if;return old.evidence;end if;
 o:=app.ph_approved_evidence(p_org,p_user,'cutoff_opening','2026-01-01');
 freq:=o.payload->>'frequency';e:=app.ph_period_end(p_start,freq);
 if e>date '2026-11-24' or (a.payload->>'end')::date is distinct from e or a.payload->>'frequency' is distinct from freq then raise exception 'period or frequency mismatch' using errcode='22023';end if;
 -- Candidate pay date is end of cutoff. Frequency fixed for year; no overlap/gap.
 select count(*) filter(where m.gross>0)::int,coalesce(sum(m.taxable),0),coalesce(sum(m.withholding),0),max(m.pay_date),
 coalesce(bool_or((m.evidence->>'cumulative')::boolean),false)
 into n,pt,pw,last_end,sticky from app.ph_effective_monetary m
 where m.organization_id=p_org and m.user_id=p_user and extract(year from m.period_start)=2026 and m.period_start<p_start;
 if p_start is distinct from coalesce(last_end+1,(o.payload->>'firstPeriod')::date) then raise exception 'noncontiguous period history' using errcode='P0001';end if;
 if o.payload->'certificates' is distinct from '[]'::jsonb or (o.payload->>'previousPeriods')::int<>0 or exists(select 1 from app.ph_2316_import where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'cutoff prior employer requires integration' using errcode='P0001';end if;
 prior:=jsonb_build_object('taxable',0,'withheld',0,'periods',0);
 select * into y from app.ph_benefit_year where organization_id=p_org and user_id=p_user and tax_year=2026;
 if not found or y.opening_through>=(o.payload->>'firstPeriod')::date
 or o.payload->'benefitOpening' is distinct from jsonb_build_object('through',y.opening_through,'buckets',y.opening_buckets,'other',y.opening_other,'medicalMode',y.medical_mode)
 then raise exception 'reviewed benefit opening mismatch' using errcode='P0001';end if;
 if exists(select 1 from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=2026 and x.paid_on<p_start
 and not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and x.paid_on between m.period_start and m.pay_date))
 then raise exception 'earlier benefit not reconciled' using errcode='P0001';end if;
 -- Reject minute-only corrections and cross-period spill on either boundary.
 if exists(select 1 from app.accounting_adjustment_proposal q where q.organization_id=p_org and q.user_id=p_user and q.period_start<=e and q.period_start+6>=p_start)
 or exists(select 1 from app.accounting_locked_snapshot q cross join lateral jsonb_array_elements(q.reconciliation->'payLines') l
 where q.organization_id=p_org and q.user_id=p_user and
 (((l->>'workday')::date between p_start and e) is distinct from ((l->>'date')::date between p_start and e)))
 then raise exception 'adjustment or cross-cutoff workday requires allocation review' using errcode='P0001';end if;
 if exists(select 1 from public.approval_requests q where q.organization_id=p_org and q.requester_id=p_user and q.kind='leave' and q.status='approved' and (q.payload->>'start')::date<=e and (q.payload->>'end')::date>=p_start) then raise exception 'cutoff leave requires approved allocation review' using errcode='P0001';end if;
 first_h:=app.ph_employment_as_of(p_org,p_user,p_start,clock_timestamp());
 if first_h.status<>'employed' then raise exception 'historically employed period required' using errcode='P0001';end if;
 if first_h.pay_basis not in ('daily','hourly','monthly') or freq not in ('daily','semi-monthly','monthly') or (first_h.pay_basis='monthly' and freq<>'monthly') then raise exception 'restricted cutoff compensation basis' using errcode='P0001';end if;
 for d in select p_start+i from generate_series(0,e-p_start)i loop
 wk:=d-(extract(isodow from d)::int-1);
 select * into ev from app.ph_workday_evidence where organization_id=p_org and user_id=p_user and work_date=d and period_start=wk;
 if not found then raise exception 'complete workday evidence required' using errcode='P0001';end if;
 h:=app.ph_employment_as_of(p_org,p_user,d,clock_timestamp());
 if h.status<>'employed' or (h.effective_on,h.recorded_at) is distinct from (ev.employment_effective_on,ev.employment_recorded_at)
 or h.pay_basis<>first_h.pay_basis or (h.pay_basis='monthly' and (h.effective_on,h.recorded_at) is distinct from (first_h.effective_on,first_h.recorded_at))
 then raise exception 'employment revision requires review' using errcode='P0001';end if;
 wa:=app.ph_wage_on(p_org,p_user,d,h.site_reference,h.wage_order_reference);
 wage:=(wa.payload->>'dailyMinimum')::numeric;

 if h.pay_basis='monthly' then
 reviewed:=app.ph_reviewed_month_salary(p_org,p_user,d,clock_timestamp());
 if (reviewed.effective_on,reviewed.recorded_at) is distinct from (h.effective_on,h.recorded_at) then raise exception 'reviewed monthly salary mismatch' using errcode='P0001';end if;
 perform app.ph_approved_evidence(p_org,p_user,'divisor',h.effective_on);
 select * into dv from app.ph_salary_divisor_evidence where (organization_id,user_id,effective_on,recorded_at)=(h.organization_id,h.user_id,h.effective_on,h.recorded_at);
 if not found then raise exception 'reviewed monthly salary divisor required' using errcode='P0001';end if;
 rate:=h.rate_php*12/dv.annual_paid_days/8;
 else rate:=case h.pay_basis when 'hourly' then h.rate_php when 'daily' then h.rate_php/8 else null end;end if;

 -- Compare without floating-point. Monthly MWE and unusual coverage require separate review.
 if rate*8<wage or (h.pay_basis='monthly' and rate*8<=wage) then raise exception 'wage underpayment or unsupported monthly MWE' using errcode='P0001';end if;
 is_mwe:=rate*8=wage;any_mwe:=any_mwe or is_mwe;any_non_mwe:=any_non_mwe or not is_mwe;
 select * into z from app.accounting_locked_snapshot where organization_id=p_org and user_id=p_user and period_start=wk;
 if not found or z.reconciliation->>'classificationVersion' is distinct from '4'
 or coalesce((z.reconciliation->>'exactOvertimeReviewSeconds')::numeric,1)<>0
 or not exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=wk)
 then raise exception 'locked exact attendance required' using errcode='P0001';end if;
 worked:=0;
 for line in select l from jsonb_array_elements(z.reconciliation->'payLines') l where (l->>'workday')::date=d loop
 secs:=(line->>'seconds')::numeric;factor:=(line->>'multiplier')::numeric;code:=line->>'code';
 if secs is null or secs<=0 or secs>86400 or factor is null or factor<1 or factor>10 or code is null or code !~ '^(REG|RD|SH|SH_RD|RH|RH_RD|DH|DH_RD)(_OT)?(_ND)?$'
 then raise exception 'invalid exact pay line' using errcode='P0001';end if;
 if is_mwe and code !~ '^(REG|RH|RH_RD|DH|DH_RD)(_OT)?(_ND)?$' then raise exception 'MWE rest/special-day exemption needs separate review' using errcode='P0001';end if;
 worked:=worked+secs;
 if code~'(^|_)OT(_|$)' then
 amount:=rate*secs/3600*factor;raw_premium:=raw_premium+amount;
 else
 amount:=rate*secs/3600*factor;
 if h.pay_basis='monthly' then raw_premium:=raw_premium+rate*secs/3600*(factor-1);
 else raw_basic:=raw_basic+rate*secs/3600;raw_premium:=raw_premium+rate*secs/3600*(factor-1);end if;
 end if;
 if is_mwe then raw_exempt:=raw_exempt+amount;end if;
 lines:=lines||jsonb_build_array(line||jsonb_build_object('hourlyRate',rate,'wageEvidence',wa.id,'employmentRevision',h.recorded_at));
 end loop;
 if worked>86400 then raise exception 'invalid total workday seconds' using errcode='P0001';end if;
 nonwork:=a.payload->'nonwork'->d::text;
 if worked>0 and nonwork is not null then raise exception 'overlapping nonwork payment' using errcode='P0001';end if;
 if worked=0 then
 if nonwork is null or jsonb_typeof(nonwork)<>'object' or length(btrim(coalesce(nonwork->>'reference','')))<8 then raise exception 'zero-work date requires disposition' using errcode='P0001';end if;
 if nonwork->>'kind' not in ('paid_leave','paid_regular_holiday','unpaid_nonwork','monthly_covered') or nonwork->>'kind' is null then raise exception 'unsupported nonwork disposition' using errcode='22023';end if;
 if nonwork->>'kind'='paid_regular_holiday' and coalesce(ev.calendar_classes->>d::text,'') not in ('regular_holiday','regular_holiday_rest') then raise exception 'holiday evidence mismatch' using errcode='P0001';end if;
 if h.pay_basis='monthly' and nonwork->>'kind'<>'monthly_covered' then raise exception 'partial monthly salary requires separate review' using errcode='P0001';end if;
 if h.pay_basis<>'monthly' and nonwork->>'kind'='monthly_covered' then raise exception 'invalid monthly coverage' using errcode='P0001';end if;
 if nonwork->>'kind' in ('paid_leave','paid_regular_holiday') then
 if nonwork->>'kind'='paid_leave' then raise exception 'cutoff paid leave requires canonical allocation review' using errcode='P0001';end if;
 amount:=rate*8;raw_basic:=raw_basic+amount;if is_mwe then raw_exempt:=raw_exempt+amount;end if;
 end if;
 lines:=lines||jsonb_build_array(nonwork||jsonb_build_object('date',d,'wageEvidence',wa.id,'employmentRevision',h.recorded_at));
 end if;
 end loop;
 if any_mwe and any_non_mwe then raise exception 'MWE status changed within period' using errcode='P0001';end if;
 if exists(select 1 from jsonb_object_keys(a.payload->'nonwork') k where k::date not between p_start and e) then raise exception 'nonwork date outside cutoff' using errcode='22023';end if;
 if first_h.pay_basis='monthly' then
 if freq='monthly' then raw_basic:=first_h.rate_php;
 elsif extract(day from p_start)=1 then raw_basic:=round(first_h.rate_php/2,2);
 else raw_basic:=first_h.rate_php-round(first_h.rate_php/2,2);end if;end if;
 basic:=round(raw_basic,2);premium:=round(raw_basic+raw_premium,2)-basic;
 qualifying:=round(raw_exempt,2);
 extra:=(a.payload->>'taxableExtras')::numeric;hazard:=(a.payload->>'hazardPay')::numeric;
 for b in select * from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=2026 and paid_on between p_start and e order by sequence_no loop
 bg:=bg+(b.result->>'gross')::numeric;be:=be+(b.result->>'gross')::numeric-(b.result->>'taxable')::numeric;
 lines:=lines||jsonb_build_array(jsonb_build_object('benefitEvent',b.event_key,'result',b.result));
 end loop;
 select coalesce(jsonb_agg(event_key order by event_key),'[]') into actual_ids from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=2026 and paid_on between p_start and e;
 if actual_ids is distinct from a.payload->'benefitKeys' then raise exception 'reviewed benefit set changed' using errcode='P0001';end if;
 gross:=basic+premium+extra+hazard+bg;
 exempt:=qualifying+be+case when any_mwe then hazard else 0 end;
 -- Monthly contribution bases are independently reviewed and allocated once
 -- to an exact payment date; no estimated or repeated deduction. Pay-month
 -- boundaries use payment date, not shift start. Partial/employer exemptions unsupported.
 mon:=date_trunc('month',e)::date;ca:=app.ph_approved_evidence(p_org,p_user,'contribution',mon);
 alloc:=(ca.payload->>'allocationDate')::date;
 if e<alloc and date_trunc('month',app.ph_period_end(e+1,freq))::date<>mon
 then raise exception 'final monthly cutoff cannot leave contributions unallocated' using errcode='P0001';end if;
 if e>alloc and not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and m.pay_date=alloc and m.evidence->>'contributionEvidence'=ca.id::text)
 then raise exception 'monthly contribution allocation missed' using errcode='P0001';end if;
 if e=alloc then
 s:=app.ph_contribution_candidate('sss',(ca.payload->>'sss')::numeric,mon);
 ph:=app.ph_contribution_candidate('philhealth',(ca.payload->>'philhealth')::numeric,mon);
 f:=app.ph_contribution_candidate('pagibig',(ca.payload->>'pagibig')::numeric,mon);
 ee:=(s->>'employee')::numeric+(ph->>'employee')::numeric+(f->>'employee')::numeric;
 er:=(s->>'employer')::numeric+(ph->>'employer')::numeric+(f->>'employer')::numeric;
 end if;
 ded:=(a.payload->>'taxDeductible')::numeric;
 if ded>least(ee,gross-exempt) or (not any_mwe and ded<>least(ee,gross-exempt)) then raise exception 'tax-deductible statutory contributions require review' using errcode='P0001';end if;
 taxable:=gross-exempt-ded;
 -- Mandatory cumulative switch for supplemental pay at/above regular taxable,
 -- or when regular taxable is below the periodic floor; sticky for the year.
 regtax:=greatest(0,basic-qualifying-ded);
 supptax:=greatest(0,taxable-regtax);
 use_average:=sticky or (prior->>'periods')::int>0 or (a.payload->>'cumulative')::boolean
 or (supptax>0 and (supptax>=regtax or app.ph_tax_candidate(regtax,freq,e)=0));
 if gross=0 then wt:=0;
 elsif use_average then
 avg_result:=app.ph_cumulative_withholding(pt+taxable+(prior->>'taxable')::numeric,n+1+(prior->>'periods')::int,pw+(prior->>'withheld')::numeric,freq,e);
 wt:=(avg_result->>'withhold')::numeric;
 else wt:=app.ph_tax_candidate(taxable,freq,e);end if;
 if gross-ee-wt<0 then raise exception 'insufficient compensation; separate reviewed settlement required' using errcode='P0001';end if;
 calc:=jsonb_build_object('sourceVersion',2,'revision',version_no,'frequency',freq,'periodStart',p_start,'periodEnd',e,'payDate',e,'basic',basic,'premium',premium,
 'gross',gross,'exempt',exempt,'mweExempt',qualifying+case when any_mwe then hazard else 0 end,'employeeContrib',ee,'employerContrib',er,
 'taxDeductible',ded,'taxable',taxable,'withholding',wt,'net',gross-ee-wt,'employerCost',gross+er,'benefitKeys',actual_ids,
 'contributions',jsonb_build_object('sss',s,'philhealth',ph,'pagibig',f),'sss',s,'philhealth',ph,'pagibig',f,'contributionEvidence',ca.id,'priorEmployer',prior,'cumulative',use_average,'averageEvidence',avg_result,'lines',lines,'attestation',a.id);

 insert into app.ph_monetary_snapshot(organization_id,period_start,user_id,pay_date,gross,employee_contributions,employer_contributions,taxable,withholding,net,evidence,posted_by,exempt,frequency,tax_deductible,revision)
 values(p_org,p_start,p_user,e,gross,ee,er,taxable,wt,gross-ee-wt,calc,auth.uid(),exempt,freq,ded,version_no);
 lines:=jsonb_build_array(jsonb_build_object('account','wage_expense','debit',gross,'credit',0),
 jsonb_build_object('account','employer_contribution_expense','debit',er,'credit',0),
 jsonb_build_object('account','net_payable','debit',0,'credit',gross-ee-wt),
 jsonb_build_object('account','withholding_payable','debit',0,'credit',wt),
 jsonb_build_object('account','sss_payable','debit',0,'credit',coalesce((s->>'total')::numeric,0)),
 jsonb_build_object('account','philhealth_payable','debit',0,'credit',coalesce((ph->>'total')::numeric,0)),
 jsonb_build_object('account','pagibig_payable','debit',0,'credit',coalesce((f->>'total')::numeric,0)));
 select sum((x->>'debit')::numeric-(x->>'credit')::numeric) into bal from jsonb_array_elements(lines)x;
 if bal<>0 then raise exception 'unbalanced journal' using errcode='P0001';end if;
 insert into app.ph_payroll_journal values(p_org,p_start,p_user,lines,gross+er,gross+er,version_no);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),case when p_replay then 'accounting.ph_cutoff_replayed' else 'accounting.ph_cutoff_posted' end,'membership',p_user::text,jsonb_build_object('periodStart',p_start,'periodEnd',e,'frequency',freq));
 return calc;
end $$;
create or replace function app.ph_record_cutoff_final(p_org uuid,p_user uuid,p_start date) returns jsonb
language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; o app.ph_payroll_attestation; s app.ph_monetary_snapshot; h app.ph_employment_history;
 t numeric; w numeric; basic numeric; paid numeric; avail numeric; j jsonb; e date;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 if app.ph_unresolved_reversal(p_org,p_user) then raise exception 'unresolved reversal' using errcode='P0001';end if;
 a:=app.ph_approved_evidence(p_org,p_user,'cutoff_final',p_start);
 if a.maker=auth.uid() then raise exception 'independent settlement required' using errcode='42501';end if;
 o:=app.ph_approved_evidence(p_org,p_user,'cutoff_opening','2026-01-01');
 select * into s from app.ph_effective_monetary where organization_id=p_org and user_id=p_user and period_start=p_start;
 if not found or s.frequency not in ('daily','semi-monthly','monthly') or exists(select 1 from app.ph_effective_monetary x where x.organization_id=p_org and x.user_id=p_user and x.period_start>p_start) then raise exception 'latest effective cutoff required' using errcode='P0001';end if;
 e:=s.pay_date;
 if not exists(select 1 from public.memberships where organization_id=p_org and user_id=p_user and status='ended')
 or exists(select 1 from app.ph_2316_import where organization_id=p_org and user_id=p_user and tax_year=2026)
 or o.payload->'certificates' is distinct from '[]'::jsonb
 or (o.payload->>'previousPeriods')::int<>0 then raise exception 'restricted final termination scope' using errcode='P0001';end if;
 h:=app.ph_employment_as_of(p_org,p_user,e+1,clock_timestamp());
 if h.status is distinct from 'separated' or h.effective_on is distinct from e+1 then raise exception 'reviewed separation required' using errcode='P0001';end if;
 if e+1<((o.payload->>'firstPeriod')::date+interval '1 month')::date
 or exists(select 1 from generate_series((o.payload->>'firstPeriod')::date,e,interval '1 day') g where not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and g::date between m.period_start and m.pay_date)) then raise exception 'complete final year coverage required' using errcode='P0001';end if;
 if exists(select 1 from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=2026 and not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and x.paid_on between m.period_start and m.pay_date and m.evidence->'benefitKeys' ? x.event_key)) then raise exception 'unreconciled benefits' using errcode='P0001';end if;
 -- All monthly liabilities must be allocated, including the final month;
 -- otherwise final settlement would silently omit statutory deductions.
 if exists(select 1 from generate_series(date_trunc('month',(o.payload->>'firstPeriod')::date)::date,date_trunc('month',e)::date,interval '1 month') g
 where not exists(select 1 from app.ph_payroll_attestation c join app.ph_payroll_attestation_decision d on d.attestation_id=c.id
 join app.ph_effective_monetary m on m.organization_id=c.organization_id and m.user_id=c.user_id and m.pay_date=(c.payload->>'allocationDate')::date and m.evidence->>'contributionEvidence'=c.id::text
 where c.organization_id=p_org and c.user_id=p_user and c.kind='contribution' and c.scope_date=g::date and m.pay_date<=e))
 then raise exception 'unallocated final contributions' using errcode='P0001';end if;
 select coalesce(sum(m.taxable),0),coalesce(sum(m.withholding),0),coalesce(sum((m.evidence->>'basic')::numeric),0) into t,w,basic from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and extract(year from m.pay_date)=2026;
 select coalesce(sum((x.result->>'gross')::numeric),0) into paid from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=2026 and x.request->>'code'='13th_month';
 if paid<>round(basic/12,2) then raise exception 'thirteenth entitlement requires reconciliation' using errcode='P0001';end if;
 avail:=(a.payload->>'available')::numeric;
 if avail>s.net then raise exception 'available final compensation exceeds accrual' using errcode='22023';end if;
 j:=app.ph_annual_adjustment(e,e,'termination',t,0,w,0,avail,a.evidence);
 insert into app.ph_annual_settlement(organization_id,user_id,tax_year,final_period,attestation_id,result,recorded_by,final_revision)
 values(p_org,p_user,2026,p_start,a.id,j,auth.uid(),s.revision);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_cutoff_final','membership',p_user::text,jsonb_build_object('period',p_start,'revision',s.revision));
 return j;
end $$;