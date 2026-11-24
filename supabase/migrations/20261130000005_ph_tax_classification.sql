-- Private pure transition; attested prior bucket and other-benefit usage required.
-- Does not persist balances or authorize classification. No unknown code defaults.
create function app.ph_compensation_classify(p_day date,p_code text,p_amount numeric,p_prior numeric,p_other_prior numeric,
 p_mwe boolean,p_evidence text,p_units numeric default null,p_regional_wage numeric default null,p_medical_mode text default null)
returns jsonb language plpgsql stable set search_path='' as $$
declare cap numeric; bucket text; dm numeric:=0; other_exempt numeric:=0; mwe_exempt numeric:=0; excess numeric:=0;
 taxable numeric; used numeric:=p_prior; v numeric; year_key text; month_key text;
begin
 if p_day is null or p_day<date '2026-01-06' or p_day>date '2026-11-24' or p_code is null or p_mwe is null
 or p_evidence is null or length(btrim(p_evidence)) not between 1 and 300 then
  raise exception 'missing supported date/classification evidence' using errcode='22023'; end if;
 foreach v in array array[p_amount,p_prior,p_other_prior] loop
  if v is null or v::text in ('NaN','Infinity','-Infinity') or v<0 or v>1000000000 or v<>round(v,2)
  then raise exception 'invalid amount or opening balance' using errcode='22023'; end if;
 end loop;
 year_key:=extract(year from p_day)::text; month_key:=to_char(p_day,'YYYY-MM');
 case p_code
 when 'rice' then cap:=2500; bucket:='rice:'||month_key;
 when 'laundry' then cap:=400; bucket:='laundry:'||month_key;
 when 'uniform' then cap:=8000; bucket:='uniform:'||year_key;
 when 'medical_assistance' then cap:=12000; bucket:='medical:'||year_key;
 when 'achievement_award' then cap:=12000; bucket:='achievement:'||year_key;
 when 'christmas_anniversary_gift' then cap:=6000; bucket:='gift:'||year_key;
 when 'cba','productivity' then cap:=12000; bucket:='cba_productivity:'||year_key;
 when 'dependent_medical' then
  if p_medical_mode='monthly' then cap:=333; bucket:='dependent_medical:'||month_key;
  elsif p_medical_mode='semester' then cap:=2000; bucket:='dependent_medical:'||year_key||'-S'||case when extract(month from p_day)<=6 then '1' else '2' end;
  else raise exception 'medical mode required' using errcode='22023'; end if;
 when 'ot_night_meal' then
  if p_regional_wage is null or p_regional_wage::text in ('NaN','Infinity','-Infinity') or p_regional_wage<=0 or p_regional_wage>1000000 or p_regional_wage<>round(p_regional_wage,2)
  then raise exception 'verified regional wage required' using errcode='22023'; end if;
  cap:=trunc(p_regional_wage*0.30,2); bucket:='ot_night_meal:'||p_day::text;
 when 'vacation_conversion' then
  if p_units is null or p_units::text in ('NaN','Infinity','-Infinity') or p_units<=0 or p_units>366 or p_units<>round(p_units,2) then
   raise exception 'verified vacation days required' using errcode='22023'; end if;
  bucket:='vacation_days:'||year_key;
  dm:=trunc(p_amount*least(p_units,greatest(0,12-p_prior))/p_units,2); used:=p_prior+p_units; excess:=p_amount-dm;
 when '13th_month','qualified_other_benefit' then excess:=p_amount;
 when 'basic','holiday','overtime','night_differential','qualifying_hazard' then
  if p_mwe then mwe_exempt:=p_amount; end if;
 when 'commission','taxable_allowance','other_taxable','nonqualifying_hazard' then null;
 else raise exception 'unsupported compensation code' using errcode='22023';
 end case;
 if p_code<>'vacation_conversion' and p_units is not null then raise exception 'unexpected units' using errcode='22023'; end if;
 if cap is not null then
  dm:=least(p_amount,greatest(0,cap-p_prior)); excess:=p_amount-dm; used:=p_prior+p_amount;
 elsif bucket is null and p_prior<>0 then raise exception 'unexpected prior bucket' using errcode='22023';
 end if;
 other_exempt:=least(excess,greatest(0,90000-p_other_prior));
 taxable:=p_amount-dm-other_exempt-mwe_exempt;
 return jsonb_build_object('gross',p_amount,'taxable',taxable,'deMinimisExempt',dm,'otherBenefitsExempt',other_exempt,
  'mweExempt',mwe_exempt,'bucket',bucket,'bucketUsage',used,'otherBenefitUsage',p_other_prior+excess);
end $$;
revoke all on function app.ph_compensation_classify(date,text,numeric,numeric,numeric,boolean,text,numeric,numeric,text) from public,anon,authenticated,service_role;

-- Annualized adjustment: verified taxable totals net of lawful contributions.
-- Current/previous employer amounts must be certified; no withholding or payout side effects.
create function app.ph_annual_adjustment(p_rule_date date,p_final_pay_date date,p_reason text,p_current_taxable numeric,
 p_previous_taxable numeric,p_current_withheld numeric,p_previous_withheld numeric,p_available numeric,p_evidence text)
returns jsonb language plpgsql stable set search_path='' as $$
declare v numeric; due numeric; delta numeric; collectible numeric; refund numeric; refund_date date;
begin
 if p_rule_date is null or p_final_pay_date is null or not isfinite(p_final_pay_date) or p_reason is null
 or p_reason not in ('termination','year_end') or extract(year from p_rule_date)<>extract(year from p_final_pay_date)
 or (p_reason='year_end' and extract(month from p_final_pay_date)<>12)
 or p_evidence is null or length(btrim(p_evidence)) not between 1 and 300 then
  raise exception 'invalid annual adjustment context' using errcode='22023'; end if;
 foreach v in array array[p_current_taxable,p_previous_taxable,p_current_withheld,p_previous_withheld,p_available] loop
  if v is null or v::text in ('NaN','Infinity','-Infinity') or v<0 or v>1000000000 or v<>round(v,2)
  then raise exception 'invalid annual amount' using errcode='22023'; end if;
 end loop;
 due:=app.ph_tax_candidate(p_current_taxable+p_previous_taxable,'annual',p_rule_date);
 delta:=due-p_current_withheld-p_previous_withheld;
 collectible:=least(greatest(0,delta),p_available);
 refund:=greatest(0,-delta);
 if refund>0 then refund_date:=case when p_reason='termination' then p_final_pay_date else make_date(extract(year from p_final_pay_date)::integer+1,1,25) end; end if;
 return jsonb_build_object('taxable',p_current_taxable+p_previous_taxable,'taxDue',due,
 'alreadyWithheld',p_current_withheld+p_previous_withheld,'adjustment',delta,'employeeWithholding',collectible,
 'employerAdvance',greatest(0,delta)-collectible,'refund',refund,'refundDue',refund_date);
end $$;
revoke all on function app.ph_annual_adjustment(date,date,text,numeric,numeric,numeric,numeric,numeric,text) from public,anon,authenticated,service_role;
