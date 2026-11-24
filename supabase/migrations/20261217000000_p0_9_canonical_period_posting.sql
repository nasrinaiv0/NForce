-- Evolve the canonical financial ledger, rather than introducing the parallel
-- PR16 monetary snapshot/journal. The historical key pay_month remains for
-- compatibility; for 2026 it identifies the inclusive period start.
alter table app.ph_money_snapshot add column frequency text not null default 'monthly';
alter table app.ph_money_snapshot add column period_end date;
alter table app.ph_money_snapshot add column pay_date date;
alter table app.ph_money_snapshot add column exempt numeric not null default 0;
alter table app.ph_money_snapshot add column tax_deductible numeric;
alter table app.ph_money_snapshot add column attestation_id uuid references app.ph_payroll_attestation(id);
alter table app.ph_money_snapshot add column legacy_pay_month date generated always as
 (case when extract(year from pay_month)=2025 then pay_month else null end) stored;
do $$ declare c text;begin
 select conname into strict c from pg_constraint where conrelid='app.ph_money_snapshot'::regclass
 and contype='f' and confrelid='app.ph_month_context_review'::regclass;
 execute format('alter table app.ph_money_snapshot drop constraint %I',c);
 select conname into strict c from pg_constraint where conrelid='app.ph_money_snapshot'::regclass
 and contype='c' and pg_get_constraintdef(oid) like '%taxable = (gross - employee_contrib)%';
 execute format('alter table app.ph_money_snapshot drop constraint %I',c);
end $$;
alter table app.ph_money_snapshot add foreign key(organization_id,user_id,legacy_pay_month) references app.ph_month_context_review(organization_id,user_id,pay_month);
alter table app.ph_money_snapshot add check(net=gross-employee_contrib-withholding and employer_cost=gross+employer_contrib
 and taxable=gross-exempt-coalesce(tax_deductible,employee_contrib) and exempt>=0
 and coalesce(tax_deductible,employee_contrib) between 0 and employee_contrib);
alter table app.ph_money_snapshot add check(
 (extract(year from pay_month)=2025 and frequency='monthly' and period_end is null and pay_date is null and attestation_id is null and exempt=0 and tax_deductible is null)
 or (pay_month between date '2026-01-06' and date '2026-11-24' and period_end is not null and pay_date is not null and pay_date=period_end
 and period_end between pay_month and date '2026-11-24' and frequency in ('daily','weekly','semi-monthly','monthly') and attestation_id is not null and tax_deductible is not null));
-- Versions share the original snapshot/journal tables, preserving legacy
-- 2025 inserts as revision 1. Reversal references always target revision 1.
alter table app.ph_money_snapshot add column revision int not null default 1 check(revision in (1,2));
alter table app.ph_money_journal add column revision int not null default 1 check(revision in (1,2));
alter table app.ph_money_reversal_proposal add column original_revision int generated always as (1) stored;
alter table app.ph_money_reversal_journal add column original_revision int generated always as (1) stored;
do $$ declare r record;begin
 for r in select conrelid::regclass t,conname from pg_constraint where contype='f' and
 (confrelid='app.ph_money_snapshot'::regclass or confrelid='app.ph_money_journal'::regclass)
 loop execute format('alter table %s drop constraint %I',r.t,r.conname);end loop;
end $$;
alter table app.ph_money_journal drop constraint ph_money_journal_pkey;
alter table app.ph_money_snapshot drop constraint ph_money_snapshot_pkey;
alter table app.ph_money_snapshot add primary key(organization_id,user_id,pay_month,revision);
alter table app.ph_money_journal add primary key(organization_id,user_id,pay_month,account_code,revision);
alter table app.ph_money_journal add foreign key(organization_id,user_id,pay_month,revision) references app.ph_money_snapshot;
alter table app.ph_money_reversal_proposal add foreign key(organization_id,user_id,pay_month,original_revision) references app.ph_money_snapshot;
alter table app.ph_money_reversal_journal add foreign key(organization_id,user_id,pay_month,account_code,original_revision) references app.ph_money_journal;
alter table app.ph_money_snapshot add check(revision=1 or extract(year from pay_month)=2026);
create view app.ph_money_active with (security_invoker=true) as
 select s.* from app.ph_money_snapshot s where s.revision=2 or not exists(select 1 from app.ph_money_reversal r
 where r.organization_id=s.organization_id and r.user_id=s.user_id and r.pay_month=s.pay_month);
revoke all on app.ph_money_active from public,anon,authenticated,service_role;

create function app.ph_money_attestation_guard() returns trigger language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;
begin
 if extract(year from new.pay_month)=2026 then
 a:=app.ph_approved_evidence(new.organization_id,new.user_id,case when new.revision=2 then 'replay' else 'period' end,new.pay_month);
 if new.revision=2 and not exists(select 1 from app.ph_money_reversal r join app.ph_money_snapshot x on (x.organization_id,x.user_id,x.pay_month,x.revision)=(r.organization_id,r.user_id,r.pay_month,1)
 where r.organization_id=new.organization_id and r.user_id=new.user_id and r.pay_month=new.pay_month
 and x.attestation_id::text=a.payload->>'originalAttestation') then raise exception 'reviewed reversal required for replay' using errcode='P0001';end if;
 if a.id is distinct from new.attestation_id or (a.payload->>'end')::date is distinct from new.period_end
 or a.payload->>'frequency' is distinct from new.frequency then raise exception 'unmatched monetary attestation' using errcode='P0001';end if;
 end if;return new;
end $$;
create trigger ph_money_attestation before insert on app.ph_money_snapshot for each row execute function app.ph_money_attestation_guard();

create function app.ph_period_end(p_start date,p_frequency text) returns date
language plpgsql immutable set search_path='' as $$
declare e date; m date;
begin
 if p_start is null or not isfinite(p_start) or p_frequency is null then raise exception 'invalid payroll period' using errcode='22023';end if;
 m:=date_trunc('month',p_start)::date;e:=(m+interval '1 month - 1 day')::date;
 case p_frequency
 when 'daily' then return p_start;
 when 'weekly' then if extract(isodow from p_start)<>1 then raise exception 'Monday required' using errcode='22023';end if;return p_start+6;
 when 'semi-monthly' then
 if p_start=m then return m+14;elsif p_start=m+15 then return e;else raise exception 'invalid semi-monthly start' using errcode='22023';end if;
 when 'monthly' then if p_start<>m then raise exception 'first day required' using errcode='22023';end if;return e;
 else raise exception 'invalid frequency' using errcode='22023';
 end case;
end $$;

-- Prior employer figures are read from the single reviewed certificate/custody store.
-- Explicit related-period count is required, never inferred from certificate dates.
create function app.ph_prior_employer_2026(p_org uuid,p_user uuid)
returns jsonb language plpgsql stable set search_path='' as $$
declare a app.ph_payroll_attestation; ids jsonb; t numeric; w numeric; n int; ct int;
begin
 a:=app.ph_approved_evidence(p_org,p_user,'opening','2026-01-01');
 if exists(select 1 from app.ph_2316_import i left join app.ph_2316_review r on r.import_id=i.id
 left join app.ph_2316_custody_review c on c.import_id=i.id and c.organization_id=i.organization_id
 where i.organization_id=p_org and i.user_id=p_user and i.tax_year=2026 and
 (r.import_id is null or (r.approved and (c.import_id is null or i.period_to>=(a.payload->>'currentStart')::date))))
 then raise exception 'prior employer source incomplete or overlapping' using errcode='P0001';end if;
 select coalesce(jsonb_agg(i.id::text order by i.id),'[]'),coalesce(sum((i.fields->>'21')::numeric),0),
 coalesce(sum((i.fields->>'25A')::numeric),0),count(*) into ids,t,w,ct
 from app.ph_2316_import i join app.ph_2316_review r on r.import_id=i.id and r.approved
 join app.ph_2316_custody_review c on c.import_id=i.id and c.organization_id=i.organization_id
 where i.organization_id=p_org and i.user_id=p_user and i.tax_year=2026;
 n:=(a.payload->>'previousPeriods')::int;
 if ids is distinct from a.payload->'certificates' or (ct=0 and n<>0) or (ct>0 and n<=0) then raise exception 'certificate set/period count mismatch' using errcode='P0001';end if;
 return jsonb_build_object('taxable',t,'withheld',w,'periods',n,'certificates',ids);
end $$;

-- Single 2026 period calculation path. All four frequencies use identical
-- locked attendance, benefit, tax, contribution and journal rules. This remains
-- a restricted private candidate: ordinary eight-hour covered employees,
-- genuine monthly-paid only on monthly/semi-monthly, no disputed time,
-- cross-cutoff overnight allocation, partial monthly salary, or final pay.
create function app.ph_post_period_version_2026(p_org uuid,p_user uuid,p_start date,p_replay boolean)
returns jsonb language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;o app.ph_payroll_attestation;wa app.ph_payroll_attestation;ca app.ph_payroll_attestation;
 h app.ph_employment_history; first_h app.ph_employment_history;ev app.ph_workday_evidence;z app.accounting_locked_snapshot;
 old app.ph_money_snapshot;y app.ph_benefit_year;b app.ph_benefit_event;original app.ph_money_snapshot; version_no int;
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
 if p_replay then
 select * into original from app.ph_money_snapshot where organization_id=p_org and user_id=p_user and pay_month=p_start and revision=1;
 if not found or not exists(select 1 from app.ph_money_reversal where organization_id=p_org and user_id=p_user and pay_month=p_start)
 or exists(select 1 from app.ph_money_snapshot where organization_id=p_org and user_id=p_user and pay_month>p_start and extract(year from pay_month)=2026)
 then raise exception 'only latest reversed original accrual can be replayed' using errcode='P0001';end if;
 a:=app.ph_approved_evidence(p_org,p_user,'replay',p_start);
 if a.payload->>'originalAttestation' is distinct from original.attestation_id::text then raise exception 'replay source mismatch' using errcode='P0001';end if;
 else
 a:=app.ph_approved_evidence(p_org,p_user,'period',p_start);
 if exists(select 1 from app.ph_money_reversal r where r.organization_id=p_org and r.user_id=p_user and extract(year from r.pay_month)=2026
 and not exists(select 1 from app.ph_money_snapshot s where (s.organization_id,s.user_id,s.pay_month,s.revision)=(r.organization_id,r.user_id,r.pay_month,2)))
 then raise exception 'reversed accrual requires reviewed replay' using errcode='P0001';end if;
 end if;
 if a.maker=auth.uid() then raise exception 'maker cannot post' using errcode='42501';end if;
 select * into old from app.ph_money_active where organization_id=p_org and user_id=p_user and pay_month=p_start;
 if found then return old.calculation;end if;
 o:=app.ph_approved_evidence(p_org,p_user,'opening','2026-01-01');
 freq:=o.payload->>'frequency';e:=app.ph_period_end(p_start,freq);
 if e>date '2026-11-24' or (a.payload->>'end')::date is distinct from e or a.payload->>'frequency' is distinct from freq then raise exception 'period or frequency mismatch' using errcode='22023';end if;
 -- Candidate pay date is end of cutoff. Frequency fixed for year; no overlap/gap.
 select count(*) filter(where gross>0)::int,coalesce(sum(taxable),0),coalesce(sum(withholding),0),max(period_end),
 coalesce(bool_or((calculation->>'cumulative')::boolean),false)
 into n,pt,pw,last_end,sticky from app.ph_money_active
 where organization_id=p_org and user_id=p_user and extract(year from pay_month)=2026;
 if p_start is distinct from coalesce(last_end+1,(o.payload->>'firstPeriod')::date) then raise exception 'noncontiguous period history' using errcode='P0001';end if;
 prior:=app.ph_prior_employer_2026(p_org,p_user);
 select * into y from app.ph_benefit_year where organization_id=p_org and user_id=p_user and tax_year=2026;
 if not found or y.opening_through>=(o.payload->>'firstPeriod')::date
 or o.payload->'benefitOpening' is distinct from jsonb_build_object('through',y.opening_through,'buckets',y.opening_buckets,'other',y.opening_other,'medicalMode',y.medical_mode)
 then raise exception 'reviewed benefit opening mismatch' using errcode='P0001';end if;
 if exists(select 1 from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=2026 and x.paid_on<p_start
 and not exists(select 1 from app.ph_money_active m where m.organization_id=p_org and m.user_id=p_user and x.paid_on between m.pay_month and m.period_end))
 then raise exception 'earlier benefit not reconciled' using errcode='P0001';end if;
 -- Reject minute-only corrections and cross-period spill on either boundary.
 if exists(select 1 from app.accounting_adjustment_proposal q where q.organization_id=p_org and q.user_id=p_user and q.period_start<=e and q.period_start+6>=p_start)
 or exists(select 1 from app.accounting_locked_snapshot q cross join lateral jsonb_array_elements(q.reconciliation->'payLines') l
 where q.organization_id=p_org and q.user_id=p_user and
 (((l->>'workday')::date between p_start and e) is distinct from ((l->>'date')::date between p_start and e)))
 then raise exception 'adjustment or cross-cutoff workday requires allocation review' using errcode='P0001';end if;
 first_h:=app.ph_employment_as_of(p_org,p_user,p_start,clock_timestamp());
 if first_h.status<>'employed' then raise exception 'historically employed period required' using errcode='P0001';end if;
 if first_h.pay_basis='monthly' and freq not in ('monthly','semi-monthly') then raise exception 'monthly salary weekly/daily allocation not supported' using errcode='P0001';end if;
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
 rate:=case h.pay_basis when 'hourly' then h.rate_php when 'daily' then h.rate_php/8 else app.ph_monthly_hourly(h.rate_php,365,2026) end;
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
 if e>alloc and not exists(select 1 from app.ph_money_active m where m.organization_id=p_org and m.user_id=p_user and m.pay_date=alloc and m.calculation->>'contributionEvidence'=ca.id::text)
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
 avg_result:=app.ph_cumulative_tax(pt+taxable+(prior->>'taxable')::numeric,n+1+(prior->>'periods')::int,pw+(prior->>'withheld')::numeric,freq,e);
 wt:=(avg_result->>'withholding')::numeric;
 else wt:=app.ph_tax_candidate(taxable,freq,e);end if;
 if gross-ee-wt<0 then raise exception 'insufficient compensation; separate reviewed settlement required' using errcode='P0001';end if;
 calc:=jsonb_build_object('sourceVersion',2,'revision',version_no,'frequency',freq,'periodStart',p_start,'periodEnd',e,'payDate',e,'basic',basic,'premium',premium,
 'gross',gross,'exempt',exempt,'mweExempt',qualifying+case when any_mwe then hazard else 0 end,'employeeContrib',ee,'employerContrib',er,
 'taxDeductible',ded,'taxable',taxable,'withholding',wt,'net',gross-ee-wt,'employerCost',gross+er,'benefitKeys',actual_ids,
 'sss',s,'philhealth',ph,'pagibig',f,'contributionEvidence',ca.id,'priorEmployer',prior,'cumulative',use_average,'averageEvidence',avg_result,'lines',lines,'attestation',a.id);
 insert into app.ph_money_snapshot(organization_id,user_id,pay_month,gross,employee_contrib,employer_contrib,taxable,withholding,net,employer_cost,calculation,created_by,
 frequency,period_end,pay_date,exempt,tax_deductible,attestation_id,revision)
 values(p_org,p_user,p_start,gross,ee,er,taxable,wt,gross-ee-wt,gross+er,calc,auth.uid(),freq,e,e,exempt,ded,a.id,version_no);
 insert into app.ph_money_journal(organization_id,user_id,pay_month,account_code,debit,credit,revision)
 select p_org,p_user,p_start,v.code,v.debit,v.credit,version_no from (values
 ('salary_expense',gross,0::numeric),('employer_contribution_expense',er,0),('salary_payable',0,gross-ee-wt),('bir_withholding_payable',0,wt),
 ('sss_regular_payable',0,coalesce((s->>'employeeRegular')::numeric+(s->>'employerRegular')::numeric,0)),
 ('sss_mpf_payable',0,coalesce((s->>'employeeMpf')::numeric+(s->>'employerMpf')::numeric,0)),
 ('sss_ec_payable',0,coalesce((s->>'employerEc')::numeric,0)),('philhealth_payable',0,coalesce((ph->>'total')::numeric,0)),('pagibig_payable',0,coalesce((f->>'total')::numeric,0))
 ) v(code,debit,credit) where v.debit<>0 or v.credit<>0;
 select coalesce(sum(debit-credit),0) into bal from app.ph_money_journal where organization_id=p_org and user_id=p_user and pay_month=p_start and revision=version_no;
 if bal<>0 then raise exception 'unbalanced journal' using errcode='P0001';end if;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),case when p_replay then 'accounting.ph_money_replayed' else 'accounting.ph_money_posted' end,'membership',p_user::text,jsonb_build_object('periodStart',p_start,'periodEnd',e,'frequency',freq));
 return calc;
end $$;
create function app.ph_post_period_2026(p_org uuid,p_user uuid,p_start date) returns jsonb
language sql set search_path='' as $$select app.ph_post_period_version_2026(p_org,p_user,p_start,false)$$;
create function app.ph_replay_period_2026(p_org uuid,p_user uuid,p_start date) returns jsonb
language sql set search_path='' as $$select app.ph_post_period_version_2026(p_org,p_user,p_start,true)$$;
-- Protect already posted benefit sets. No late entry is silently ignored.
create function app.ph_guard_posted_benefit() returns trigger language plpgsql set search_path='' as $$
begin
 perform app.accounting_tenant_lock(new.organization_id);
 if exists(select 1 from app.ph_money_snapshot s where s.organization_id=new.organization_id and s.user_id=new.user_id and new.paid_on between s.pay_month and s.period_end)
 then raise exception 'posted benefit requires correction replay' using errcode='42501';end if;return new;
end $$;
create trigger p09_posted_benefit before insert on app.ph_benefit_event for each row execute function app.ph_guard_posted_benefit();
revoke all on function app.ph_money_attestation_guard(),app.ph_period_end(date,text),app.ph_prior_employer_2026(uuid,uuid),
app.ph_post_period_version_2026(uuid,uuid,date,boolean),app.ph_post_period_2026(uuid,uuid,date),app.ph_replay_period_2026(uuid,uuid,date),app.ph_guard_posted_benefit() from public,anon,authenticated,service_role;
