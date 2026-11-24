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
      raise exception 'PhilHealth schedule outside verified months' using errcode='22023';
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
'Unapproved private PH monthly contribution arithmetic for ordinary covered employees. SSS 2024-006, PhilHealth PA2025-0002 and PA2026-0042; PIA May 14 2026, HDMF 460. Classified bases, eligibility and rounding require independent review.';

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
 -- DOLE LA21-26. Round upward to a cent to avoid understating a statutory minimum.
 entitlement:=ceil((p_basic+p_maternity_differential+p_integrated_basic)*100/12)/100;
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
