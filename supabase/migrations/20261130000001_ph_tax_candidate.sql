-- Staging-only candidate, no public RPC. Inputs are independently classified taxable PHP.
-- RR 11-2018 Annex E (2023 onwards), TRAIN annual table. No implicit extrapolation
-- beyond research cutoff; daily top bracket malformed in official Annex E.
-- Numeric half-up and lower-bound cent interpretation require independent CPA signoff.
create function app.ph_tax_candidate(p_taxable numeric,p_frequency text,p_rule_date date)
returns numeric language plpgsql immutable set search_path = '' as $$
declare
  thresholds numeric[];
  bases numeric[];
  rates numeric[] := array[0.15,0.20,0.25,0.30,0.35];
  i integer;
begin
  if p_taxable is null or p_taxable::text in ('NaN','Infinity','-Infinity')
     or p_taxable < 0 or p_taxable > 1000000000
     or p_taxable <> round(p_taxable,2) or p_frequency is null
     or p_rule_date is null or p_rule_date < date '2023-01-01'
     or p_rule_date > date '2026-11-24' then
    raise exception 'unsupported taxable amount or rule date' using errcode='22023';
  end if;
  case p_frequency
  when 'daily' then
    if p_taxable >= 21918 then
      raise exception 'daily top bracket requires verified BIR clarification' using errcode='22023';
    end if;
    thresholds := array[685,1096,2192,5479,21918];
    bases := array[0,61.65,280.85,1102.60,0];
  when 'weekly' then
    thresholds := array[4808,7692,15385,38462,153846];
    bases := array[0,432.60,1971.20,7740.45,42355.65];
  when 'semi-monthly' then
    thresholds := array[10417,16667,33333,83333,333333];
    bases := array[0,937.50,4270.70,16770.70,91770.70];
  when 'monthly' then
    thresholds := array[20833,33333,66667,166667,666667];
    bases := array[0,1875,8541.80,33541.80,183541.80];
  when 'annual' then
    thresholds := array[250000,400000,800000,2000000,8000000];
    bases := array[0,22500,102500,402500,2202500];
  else
    raise exception 'unsupported tax calculation frequency' using errcode='22023';
  end case;
  for i in reverse 5..1 loop
    if p_taxable >= thresholds[i] then
      return round(bases[i]+(p_taxable-thresholds[i])*rates[i],2);
    end if;
  end loop;
  return 0.00;
end $$;
revoke all on function app.ph_tax_candidate(numeric,text,date) from public,anon,authenticated,service_role;
comment on function app.ph_tax_candidate(numeric,text,date) is
'Unapproved PH tax arithmetic candidate, no API exposure. Annex E 2023 and TRAIN; source ambiguities and rounding await CPA. Does not classify gross compensation or annualize.';
