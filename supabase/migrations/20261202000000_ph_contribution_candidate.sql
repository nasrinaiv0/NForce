-- Private arithmetic candidates only. Inputs are distinct, independently classified monthly agency bases.
-- No eligibility, deduction allocation, remittance or public execution.
create function app.ph_contribution_candidate(p_agency text,p_basis numeric,p_month date)
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
    if p_month < date '2025-01-01' or p_month > date '2025-12-01' then
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
'Unapproved private PH monthly contribution arithmetic for ordinary covered employees. SSS 2024-006, PhilHealth 2025-0002 only, HDMF 460. Classified bases, eligibility and rounding require independent review.';
