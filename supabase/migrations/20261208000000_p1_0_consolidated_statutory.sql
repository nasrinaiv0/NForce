-- Bounded money primitives. All entitlements below require independently reviewed
-- coverage and evidence; they do not decide legal eligibility or release funds.
create function app.ph_stat_money(p_value numeric) returns boolean
language sql immutable set search_path='' as $$
 select coalesce(p_value>=0 and p_value<=1000000000 and p_value=round(p_value,2),false)
$$;
create function app.ph_thirteenth_amount(p_basic numeric,p_maternity_differential numeric,p_integrated_basic numeric,p_paid numeric,p_eligible boolean,p_ref text)
returns jsonb language plpgsql immutable set search_path='' as $$
declare entitlement numeric;
begin
 if not app.ph_stat_money(p_basic) or not app.ph_stat_money(p_maternity_differential) or not app.ph_stat_money(p_integrated_basic) or not app.ph_stat_money(p_paid)
 or p_eligible is distinct from true or p_ref is null or length(btrim(p_ref)) not between 8 and 300 then raise exception 'reviewed eligible basic salary required' using errcode='22023'; end if;
 -- DOLE LA21-26. Round to cents as illustrated in the 2026 advisory.
 entitlement:=round((p_basic+p_maternity_differential+p_integrated_basic)/12,2);
 return jsonb_build_object('eligibleBasic',p_basic+p_maternity_differential+p_integrated_basic,'minimum',entitlement,'alreadyPaid',p_paid,
 'remaining',greatest(0,entitlement-p_paid),'excessToReview',greatest(0,p_paid-entitlement));
end $$;
create function app.ph_maternity_amount(p_kind text,p_solo boolean,p_full_pay numeric,p_ee_contrib numeric,p_sss_actual numeric,p_eligible boolean,p_ref text)
returns jsonb language plpgsql immutable set search_path='' as $$
declare days int; differential numeric;
begin
 if p_kind is null or p_kind not in ('live_birth','miscarriage','emergency_termination') or p_solo is null or p_eligible is distinct from true
 or not app.ph_stat_money(p_full_pay) or p_full_pay<=0 or not app.ph_stat_money(p_ee_contrib) or p_ee_contrib>p_full_pay
 or not app.ph_stat_money(p_sss_actual) or p_sss_actual<=0 or p_ref is null or length(btrim(p_ref)) not between 8 and 300
 then raise exception 'reviewed covered maternity compensation required' using errcode='22023'; end if;
 -- Non-exempt employer; no transferred days, unpaid extension or split claims.
 days:=case when p_kind='live_birth' then case when p_solo then 120 else 105 end else 60 end;
 differential:=greatest(0,p_full_pay-p_ee_contrib-p_sss_actual);
 return jsonb_build_object('paidDays',days,'fullPay',p_full_pay,'employeeContributions',p_ee_contrib,
 'sssAdvance',p_sss_actual,'salaryDifferential',differential,'taxExemptDifferential',differential,'thirteenthBasic',differential,
 'sssReimbursementReceivable',p_sss_actual);
end $$;
-- Leave days are in the legally applicable entitlement unit (working days for
-- SIL/solo parent, reviewed paid days for paternity and VAWC). Not a booking ledger.
create function app.ph_leave_amount(p_code text,p_prior_days numeric,p_days numeric,p_daily_rate numeric,p_service_months integer,p_event_no integer,p_eligible boolean,p_ref text)
returns jsonb language plpgsql immutable set search_path='' as $$
declare cap numeric;
begin
 if not app.ph_stat_money(p_prior_days) or not app.ph_stat_money(p_days) or p_days<=0
 or not app.ph_stat_money(p_daily_rate) or p_daily_rate<=0 or p_service_months is null or p_service_months<0
 or p_eligible is distinct from true or p_ref is null or length(btrim(p_ref)) not between 8 and 300 then raise exception 'reviewed leave eligibility required' using errcode='22023'; end if;
 case p_code
 when 'sil' then if p_service_months<12 then raise exception 'SIL service threshold not met' using errcode='22023'; end if; cap:=5;
 when 'solo_parent' then if p_service_months<6 then raise exception 'solo parent service threshold not met' using errcode='22023'; end if; cap:=7;
 when 'paternity' then if p_event_no is null or p_event_no not between 1 and 4 then raise exception 'paternity delivery eligibility requires review' using errcode='22023'; end if; cap:=7;
 when 'vawc' then cap:=10; -- court-ordered extensions require separate review
 else raise exception 'unsupported leave category' using errcode='22023';
 end case;
 if p_prior_days+p_days>cap then raise exception 'minimum statutory leave cap exceeded; review more favorable policy or extension' using errcode='22023'; end if;
 return jsonb_build_object('paidDays',p_days,'statutoryCap',cap,'remainingDays',cap-p_prior_days-p_days,
 'paidAmount',round(p_days*p_daily_rate,2),'cashConversionCandidate',p_code='sil');
end $$;
create function app.ph_special_women_leave(p_monthly_gross numeric,p_months numeric,p_service_in_last_12 int,p_eligible boolean,p_ref text)
returns numeric language plpgsql immutable set search_path='' as $$
begin
 if not app.ph_stat_money(p_monthly_gross) or p_monthly_gross<=0 or p_months is null or p_months<=0 or p_months>2
 or p_service_in_last_12 is null or p_service_in_last_12 not between 6 and 12 or p_eligible is distinct from true
 or p_ref is null or length(btrim(p_ref)) not between 8 and 300 then raise exception 'reviewed surgical leave duration and eligibility required' using errcode='22023'; end if;
 return round(p_monthly_gross*p_months,2);
end $$;
create function app.ph_separation_amount(p_cause text,p_monthly_base numeric,p_service_months int,p_eligible boolean,p_ref text)
returns jsonb language plpgsql immutable set search_path='' as $$
declare years int; factor numeric;
begin
 if not app.ph_stat_money(p_monthly_base) or p_monthly_base<=0 or p_service_months is null or p_service_months not between 0 and 1200
 or p_eligible is distinct from true or p_ref is null or length(btrim(p_ref)) not between 8 and 300 then raise exception 'reviewed separation basis and cause required' using errcode='22023'; end if;
 factor:=case p_cause when 'redundancy' then 1 when 'labor_saving_device' then 1 when 'retrenchment' then .5 when 'closure_without_serious_losses' then .5 when 'disease' then .5 else null end;
 if factor is null then raise exception 'unsupported cause requires legal review' using errcode='22023'; end if;
 years:=(p_service_months+6)/12;
 return jsonb_build_object('creditedYears',years,'monthlyBaseIncludingRegularAllowances',p_monthly_base,'factor',factor,'minimum',round(greatest(p_monthly_base,p_monthly_base*years*factor),2));
end $$;
create function app.ph_retirement_amount(p_daily_base numeric,p_service_months int,p_age int,p_eligible boolean,p_ref text)
returns jsonb language plpgsql immutable set search_path='' as $$
declare years int;
begin
 if not app.ph_stat_money(p_daily_base) or p_daily_base<=0 or p_service_months is null or p_service_months not between 60 and 1200
 or p_age is null or p_age not between 60 and 65 or p_eligible is distinct from true
 or p_ref is null or length(btrim(p_ref)) not between 8 and 300 then raise exception 'reviewed statutory retirement coverage required' using errcode='22023'; end if;
 years:=(p_service_months+6)/12;
 return jsonb_build_object('creditedYears',years,'daysPerYear',22.5,'minimum',round(p_daily_base*22.5*years,2));
end $$;
revoke all on function app.ph_stat_money(numeric),app.ph_thirteenth_amount(numeric,numeric,numeric,numeric,boolean,text),
app.ph_maternity_amount(text,boolean,numeric,numeric,numeric,boolean,text),app.ph_leave_amount(text,numeric,numeric,numeric,integer,integer,boolean,text),
app.ph_special_women_leave(numeric,numeric,int,boolean,text),app.ph_separation_amount(text,numeric,int,boolean,text),
app.ph_retirement_amount(numeric,int,int,boolean,text) from public,anon,authenticated,service_role;

-- Read-only cutoff quotation. Inputs require reviewed gross earning and deduction
-- evidence, not an authoritative payout or a new parallel monetary ledger.
-- Allocate monthly contributions using cumulative target less prior installments;
-- the final installment takes rounding residual. Not proof of prior actual deductions.
create function app.ph_cutoff_contribution(p_agency text,p_basis numeric,p_month date,p_slots int,p_slot int)
returns jsonb language plpgsql immutable set search_path='' as $$
declare j jsonb; ee numeric; er numeric; k text; v numeric; result jsonb:='{}';
begin
 if p_slots is null or p_slots not between 1 and 31 or p_slot is null or p_slot not between 1 and p_slots
 then raise exception 'invalid contribution installment schedule' using errcode='22023'; end if;
 j:=app.ph_contribution_candidate(p_agency,p_basis,p_month);
 -- Allocate each subcomponent independently (SSS split regular, MPF, EC).
 if p_agency='sss' then
 foreach k in array array['employeeRegular','employeeMpf','employerRegular','employerMpf','employerEc'] loop
  v:=(j->>k)::numeric;
  result:=result||jsonb_build_object(k,round(v*p_slot/p_slots,2)-round(v*(p_slot-1)/p_slots,2));
 end loop;
 ee:=(result->>'employeeRegular')::numeric+(result->>'employeeMpf')::numeric;
 er:=(result->>'employerRegular')::numeric+(result->>'employerMpf')::numeric+(result->>'employerEc')::numeric;
 else
 ee:=round((j->>'employee')::numeric*p_slot/p_slots,2)-round((j->>'employee')::numeric*(p_slot-1)/p_slots,2);
 er:=round((j->>'employer')::numeric*p_slot/p_slots,2)-round((j->>'employer')::numeric*(p_slot-1)/p_slots,2);
 end if;
 return result||jsonb_build_object('employee',ee,'employer',er,'total',ee+er,'monthly',j,'slot',p_slot,'slots',p_slots);
end $$;
-- Reuse canonical benefit events, and the existing BIR classifier, tax table and
-- contribution primitives. No changes to source events or duplicate consumption.
create function app.ph_2026_cutoff_quote(p_org uuid,p_user uuid,p_start date,p_end date,p_paid_on date,p_frequency text,
 p_regular numeric,p_qualifying_premium numeric,p_hazard numeric,p_taxable_extra numeric,p_mwe boolean,p_min_daily numeric,
 p_sss_basis numeric,p_ph_basis numeric,p_hdmf_basis numeric,p_slots int,p_slot int,p_tax_deductible numeric,
 p_prior_taxable numeric,p_prior_withheld numeric,p_period_count int,p_cumulative boolean,p_ref text)
returns jsonb language plpgsql stable set search_path='' as $$
declare h app.ph_employment_history; hist app.ph_employment_history; d date; m date; last_day date; s jsonb; ph jsonb; f jsonb;
 b_gross numeric; b_taxable numeric; b_ids jsonb; ee numeric; er numeric; g numeric; t numeric; w numeric; exempt numeric; a jsonb;
begin
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_start is null or p_end is null or p_paid_on is null or p_start>p_end or p_end>p_paid_on
 or p_start<date '2026-01-01' or p_paid_on not between date '2026-01-06' and date '2026-11-24'
 or date_trunc('month',p_start)<>date_trunc('month',p_end) or date_trunc('month',p_end)<>date_trunc('month',p_paid_on)
 or p_frequency is null or p_frequency not in ('daily','semi-monthly') or p_mwe is null or p_cumulative is null
 or p_ref is null or length(btrim(p_ref)) not between 8 and 300
 then raise exception 'unsupported cutoff context' using errcode='22023'; end if;
 m:=date_trunc('month',p_start)::date;last_day:=(m+interval '1 month - 1 day')::date;
 if p_frequency='daily' and p_start<>p_end then raise exception 'daily period must be one day' using errcode='22023'; end if;
 if p_frequency='semi-monthly' and (p_slots is distinct from 2 or not ((p_start=m and p_end=m+14 and p_slot=1)
 or (p_start=m+15 and p_end=last_day and p_slot=2))) then raise exception 'invalid semi-monthly cutoff' using errcode='22023'; end if;
 if not app.ph_stat_money(p_regular) or not app.ph_stat_money(p_qualifying_premium) or not app.ph_stat_money(p_hazard)
 or not app.ph_stat_money(p_taxable_extra) or not app.ph_stat_money(p_min_daily) or p_min_daily<=0
 or not app.ph_stat_money(p_tax_deductible) or not app.ph_stat_money(p_prior_taxable) or not app.ph_stat_money(p_prior_withheld)
 or p_period_count is null or p_period_count not between 1 and (case p_frequency when 'daily' then 366 else 24 end)
 then raise exception 'invalid monetary evidence' using errcode='22023'; end if;
 h:=app.ph_employment_as_of(p_org,p_user,p_start,clock_timestamp());
 if h.status<>'employed' or h.pay_basis<>'daily' or h.rate_php<p_min_daily or (p_mwe is distinct from (h.rate_php=p_min_daily))
 then raise exception 'daily wage/MWE classification requires reviewed historical evidence' using errcode='P0001'; end if;
 for d in select p_start+i from generate_series(0,p_end-p_start)i loop
 hist:=app.ph_employment_as_of(p_org,p_user,d,clock_timestamp());
 if (hist.effective_on,hist.recorded_at) is distinct from (h.effective_on,h.recorded_at) then raise exception 'rate changed within cutoff' using errcode='P0001'; end if;
 end loop;
 -- Require opening benefit history even if no benefit was paid on this date.
 if not exists(select 1 from app.ph_benefit_year y where y.organization_id=p_org and y.user_id=p_user and y.tax_year=2026 and y.opening_through<p_paid_on)
 then raise exception 'reviewed benefit opening required' using errcode='P0001'; end if;
 select coalesce(sum((e.result->>'gross')::numeric),0),coalesce(sum((e.result->>'taxable')::numeric),0),
 coalesce(jsonb_agg(e.event_key order by e.sequence_no),'[]'::jsonb)
 into b_gross,b_taxable,b_ids from app.ph_benefit_event e where e.organization_id=p_org and e.user_id=p_user and e.tax_year=2026 and e.paid_on=p_paid_on;
 s:=app.ph_cutoff_contribution('sss',p_sss_basis,m,p_slots,p_slot);
 ph:=app.ph_cutoff_contribution('philhealth',p_ph_basis,m,p_slots,p_slot);
 f:=app.ph_cutoff_contribution('pagibig',p_hdmf_basis,m,p_slots,p_slot);
 ee:=(s->>'employee')::numeric+(ph->>'employee')::numeric+(f->>'employee')::numeric;
 er:=(s->>'employer')::numeric+(ph->>'employer')::numeric+(f->>'employer')::numeric;
 g:=p_regular+p_qualifying_premium+p_hazard+p_taxable_extra+b_gross;
 -- Existing MWE rule applies only to verified statutory components. Extra taxable
 -- compensation remains taxable; deduction attribution for mixed earnings must be attested.
 exempt:=case when p_mwe then p_regular+p_qualifying_premium+p_hazard else 0 end;
 t:=g-exempt-(b_gross-b_taxable);
 if p_tax_deductible>least(ee,t) or (not p_mwe and p_tax_deductible<>least(ee,t))
 then raise exception 'contribution tax attribution requires reconciliation' using errcode='P0001'; end if;
 t:=t-p_tax_deductible;
 if p_cumulative then a:=app.ph_cumulative_withholding(p_prior_taxable+t,p_period_count,p_prior_withheld,p_frequency,p_paid_on);w:=(a->>'withhold')::numeric;
 else w:=app.ph_tax_candidate(t,p_frequency,p_paid_on);end if;
 if g-ee-w<0 then raise exception 'insufficient net compensation' using errcode='P0001'; end if;
 return jsonb_build_object('quoteOnly',true,'frequency',p_frequency,'gross',g,'mweExempt',exempt,'benefitGross',b_gross,'benefitTaxable',b_taxable,
 'benefitEventKeys',b_ids,'employeeContrib',ee,'employerContrib',er,'taxDeductibleContrib',p_tax_deductible,'taxable',t,'withholding',w,
 'net',g-ee-w,'employerCost',g+er,'sss',s,'philhealth',ph,'pagibig',f,'averageEvidence',a,'employmentEffectiveOn',h.effective_on,'employmentRecordedAt',h.recorded_at);
end $$;
revoke all on function app.ph_cutoff_contribution(text,numeric,date,int,int),
app.ph_2026_cutoff_quote(uuid,uuid,date,date,date,text,numeric,numeric,numeric,numeric,boolean,numeric,numeric,numeric,numeric,int,int,numeric,numeric,numeric,int,boolean,text)
from public,anon,authenticated,service_role;


-- P1.0 isolated consolidation. No public posting or export.
-- Reuse P0.8 contribution and cumulative tax implementation, P0.9 monetary and journal tables.
create function public.payroll_management_snapshot(p_organization_id uuid,p_period_start date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); n int; v jsonb; g numeric; ee numeric; er numeric; t numeric; x numeric; net numeric;
begin
 if u is null or p_period_start is null or extract(isodow from p_period_start)<>1 then raise exception 'review unavailable' using errcode='42501'; end if;
 perform app.accounting_tenant_lock(p_organization_id);
 if not app.is_member(p_organization_id) or not app.has_permission(p_organization_id,'payroll.prepare')
 or not exists(select 1 from app.accounting_review_access a where a.organization_id=p_organization_id and a.expires_at>clock_timestamp())
 then raise exception 'review unavailable' using errcode='42501'; end if;
 if not exists(select 1 from public.payroll_periods where organization_id=p_organization_id and period_start=p_period_start)
 or exists(select 1 from app.accounting_locked_snapshot s where s.organization_id=p_organization_id and s.period_start=p_period_start
 and not exists(select 1 from app.ph_monetary_snapshot m join app.ph_payroll_journal j using(organization_id,period_start,user_id)
 where (m.organization_id,m.period_start,m.user_id)=(s.organization_id,s.period_start,s.user_id)))
 or exists(select 1 from app.accounting_adjustment_proposal a where a.organization_id=p_organization_id and a.period_start=p_period_start)
 then raise exception 'complete original monetary review required' using errcode='P0001'; end if;
 select count(*)::int,sum(m.gross),sum(m.employee_contributions),sum(m.employer_contributions),sum(m.withholding),sum(m.exempt),sum(m.net)
 into n,g,ee,er,t,x,net from app.ph_monetary_snapshot m where m.organization_id=p_organization_id and m.period_start=p_period_start;
 if n=0 or g-ee-t<>net then raise exception 'monetary reconciliation unavailable' using errcode='P0001'; end if;
 return jsonb_build_object('organizationId',p_organization_id,'periodStart',p_period_start,'source','original-posted-accrual-v1',
 'employeeCount',n,'grossCents',(g*100)::numeric(30,0)::text,'employeeContributionCents',(ee*100)::numeric(30,0)::text,
 'employerContributionCents',(er*100)::numeric(30,0)::text,'withholdingCents',(t*100)::numeric(30,0)::text,
 'exemptCents',(x*100)::numeric(30,0)::text,'netCents',(net*100)::numeric(30,0)::text,'employerCostCents',((g+er)*100)::numeric(30,0)::text);
end $$;
revoke all on function public.payroll_management_snapshot(uuid,date) from public,anon,authenticated,service_role;
grant execute on function public.payroll_management_snapshot(uuid,date) to authenticated;

-- Prepare a single immutable approved statutory calculation against existing
-- maker-checker evidence. This is NOT a paid benefit or monetary posting.
alter table app.ph_payroll_attestation drop constraint ph_payroll_attestation_kind_check;
alter table app.ph_payroll_attestation add check(kind in ('opening','month','divisor','week','annual','salary_month','settlement_journal','custody_policy','statutory_quote'));
create function app.ph_reviewed_statutory_quote(p_org uuid,p_user uuid,p_day date)
returns jsonb language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; y jsonb; result jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 a:=app.ph_approved_evidence(p_org,p_user,'statutory_quote',p_day);
 y:=a.payload;
 case y->>'category'
 when 'thirteenth' then result:=app.ph_thirteenth_amount((y->>'basic')::numeric,(y->>'maternity')::numeric,(y->>'integratedBasic')::numeric,(y->>'paid')::numeric,(y->>'eligible')::boolean,a.evidence);
 when 'maternity' then result:=app.ph_maternity_amount(y->>'kind',(y->>'solo')::boolean,(y->>'fullPay')::numeric,(y->>'employeeContributions')::numeric,(y->>'sssActual')::numeric,(y->>'eligible')::boolean,a.evidence);
 when 'leave' then result:=app.ph_leave_amount(y->>'code',(y->>'priorDays')::numeric,(y->>'days')::numeric,(y->>'dailyRate')::numeric,(y->>'serviceMonths')::int,(y->>'eventNo')::int,(y->>'eligible')::boolean,a.evidence);
 when 'special_women' then result:=jsonb_build_object('paidAmount',app.ph_special_women_leave((y->>'monthlyGross')::numeric,(y->>'months')::numeric,(y->>'serviceMonths')::int,(y->>'eligible')::boolean,a.evidence));
 when 'separation' then result:=app.ph_separation_amount(y->>'cause',(y->>'monthlyBase')::numeric,(y->>'serviceMonths')::int,(y->>'eligible')::boolean,a.evidence);
 when 'retirement' then result:=app.ph_retirement_amount((y->>'dailyBase')::numeric,(y->>'serviceMonths')::int,(y->>'age')::int,(y->>'eligible')::boolean,a.evidence);
 else raise exception 'unsupported statutory category' using errcode='22023';
 end case;
 return jsonb_build_object('quoteOnly',true,'attestationId',a.id,'category',y->>'category','result',result);
end $$;
revoke all on function app.ph_reviewed_statutory_quote(uuid,uuid,date) from public,anon,authenticated,service_role;

create or replace function app.ph_approve_payroll_evidence(p_org uuid,p_id uuid,p_evidence text)
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
