-- Read-only personal evidence, never a second monetary calculation.
create function public.payroll_self_detail(p_organization_id uuid,p_period_start date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare base jsonb;s app.ph_monetary_snapshot;l jsonb;items jsonb:='[]';d date;site text;basis text;code text;amt numeric;rate numeric;factor numeric;duration numeric;method text;
begin
 base:=public.payroll_self_snapshot(p_organization_id,p_period_start);
 select m.* into strict s from app.ph_effective_monetary m where m.organization_id=p_organization_id and m.user_id=auth.uid() and m.period_start=p_period_start and m.revision=(base->>'revision')::int;
 for l in select x from jsonb_array_elements(coalesce(s.evidence->'earnings',s.evidence->'lines','[]'::jsonb)) x loop
  d:=coalesce(l->>'workday',l->>'date')::date;
  code:=coalesce(l->>'code',l->>'kind',case when l?'benefitEvent' then 'benefit' else 'other_recorded' end);
  if code !~ '^(REG|RD|SH|SH_RD|RH|RH_RD|DH|DH_RD)(_OT)?(_ND)?$' and code not in ('guaranteed_salary','paid_leave','paid_regular_holiday','unpaid_nonwork','monthly_covered','maternity_covered','commission','taxable_allowance','other_taxable','benefit') then code:='other_recorded';end if;
  site:=null;basis:=null;
  if d is not null and l?'employmentRevision' then
   select h.site_reference,h.pay_basis::text into site,basis from app.ph_employment_history h
   where h.organization_id=s.organization_id and h.user_id=s.user_id and h.recorded_at=(l->>'employmentRevision')::timestamptz and h.effective_on<=d order by h.effective_on desc limit 1;
  end if;
  amt:=null;rate:=null;factor:=null;duration:=null;
  if l?'seconds' then duration:=(l->>'seconds')::numeric;elsif l?'minutes' then duration:=(l->>'minutes')::numeric*60;end if;
  if l?'hourlyRate' then rate:=(l->>'hourlyRate')::numeric;end if;
  if l?'multiplier' then factor:=(l->>'multiplier')::numeric;end if;
  if l?'unroundedAmount' then amt:=(l->>'unroundedAmount')::numeric;
  elsif l?'amount' and code in ('guaranteed_salary','commission','taxable_allowance','other_taxable') then amt:=(l->>'amount')::numeric;
  elsif code='benefit' then amt:=(l->'result'->>'gross')::numeric;end if;
  method:=case when rate is not null and factor is not null and basis='monthly' and code not like '%_OT%' then 'monthly_increment'
   when rate is not null and factor is not null then 'hourly_factor'
   when code='guaranteed_salary' then 'salary_allocation' when code='benefit' then 'recorded_benefit' when amt is not null then 'recorded_amount' else 'period_total_only' end;
  items:=items||jsonb_build_array(jsonb_build_object('date',d,'code',code,'start',case when l?'start' then (l->>'start')::timestamptz else null end,'end',case when l?'end' then (l->>'end')::timestamptz else null end,
   'seconds',duration::text,'hourlyRate',rate::text,'multiplier',factor::text,'recordedAmount',amt::text,'siteReference',left(site,160),'method',method));
 end loop;
 return jsonb_build_object('summary',base,'frequency',s.frequency,'exemptCents',(s.exempt*100)::numeric(30,0)::text,'taxableCents',(s.taxable*100)::numeric(30,0)::text,
 'taxDeductibleCents',(s.tax_deductible*100)::numeric(30,0)::text,'basicCents',case when s.evidence?'basic' then ((s.evidence->>'basic')::numeric*100)::numeric(30,0)::text else null end,
 'premiumCents',case when s.evidence?'premium' then ((s.evidence->>'premium')::numeric*100)::numeric(30,0)::text else null end,
 'items',items,'paymentConfirmed',false);
end $$;
revoke all on function public.payroll_self_detail(uuid,date) from public,anon,authenticated,service_role;
grant execute on function public.payroll_self_detail(uuid,date) to authenticated;
