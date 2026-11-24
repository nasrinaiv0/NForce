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
 if p_cumulative then a:=app.ph_cumulative_tax(p_prior_taxable+t,p_period_count,p_prior_withheld,p_frequency,p_paid_on);w:=(a->>'withholding')::numeric;
 else w:=app.ph_tax_candidate(t,p_frequency,p_paid_on);end if;
 if g-ee-w<0 then raise exception 'insufficient net compensation' using errcode='P0001'; end if;
 return jsonb_build_object('quoteOnly',true,'frequency',p_frequency,'gross',g,'mweExempt',exempt,'benefitGross',b_gross,'benefitTaxable',b_taxable,
 'benefitEventKeys',b_ids,'employeeContrib',ee,'employerContrib',er,'taxDeductibleContrib',p_tax_deductible,'taxable',t,'withholding',w,
 'net',g-ee-w,'employerCost',g+er,'sss',s,'philhealth',ph,'pagibig',f,'averageEvidence',a,'employmentEffectiveOn',h.effective_on,'employmentRecordedAt',h.recorded_at);
end $$;
revoke all on function app.ph_cutoff_contribution(text,numeric,date,int,int),
app.ph_2026_cutoff_quote(uuid,uuid,date,date,date,text,numeric,numeric,numeric,numeric,boolean,numeric,numeric,numeric,numeric,int,int,numeric,numeric,numeric,int,boolean,text)
from public,anon,authenticated,service_role;
