\set ON_ERROR_STOP on
begin;
create function pg_temp.check_contrib(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAILED: %',label; end if; end $$;
create function pg_temp.invalid_contrib(a text,b numeric,d date) returns void language plpgsql as $$
begin
  perform app.ph_contribution_candidate(a,b,d);
  raise exception 'invalid contribution accepted';
exception when sqlstate '22023' then null;
end $$;
do $$
declare m integer; b numeric; r jsonb; lo numeric; hi numeric; n integer:=0; reg integer; mpf integer; ec integer;
begin
  for m in select generate_series(5000,35000,500) loop
    lo:=case when m=5000 then 0.01 else m-250 end;
    hi:=case when m=35000 then 1000000000 else m+249.99 end;
    reg:=least(m,20000); mpf:=m-reg; ec:=case when m>=15000 then 30 else 10 end;
    foreach b in array array[lo,m::numeric,hi] loop
      r:=app.ph_contribution_candidate('sss',b,'2025-01-01');
      perform pg_temp.check_contrib((r->>'msc')::numeric=m and
        (r->>'employeeRegular')::numeric=reg*0.05 and (r->>'employerRegular')::numeric=reg*0.10 and
        (r->>'employeeMpf')::numeric=mpf*0.05 and (r->>'employerMpf')::numeric=mpf*0.10 and
        (r->>'employerEc')::numeric=ec and (r->>'employee')::numeric=m*0.05 and
        (r->>'employer')::numeric=m*0.10+ec and (r->>'total')::numeric=m*0.15+ec,
        'SSS bracket '||m||' at '||b);
      n:=n+1;
    end loop;
  end loop;
  raise notice '% SSS bracket cases passed',n;
end $$;
do $$
declare r record; actual jsonb; n integer:=0;
begin
  for r in select * from (values
    ('sss',30000,1500,3030),('sss',35000,1750,3530),
    ('philhealth',9999.99,250,250),('philhealth',10000,250,250),
    ('philhealth',10000.20,250,250.01),('philhealth',30000,750,750),
    ('philhealth',99999.99,2500,2500),('philhealth',100000,2500,2500),
    ('philhealth',100000.01,2500,2500),
    ('pagibig',1499.99,15,30),('pagibig',1500,15,30),('pagibig',1500.01,30,30),
    ('pagibig',9999.99,200,200),('pagibig',10000,200,200),('pagibig',30000,200,200)
  ) as v(agency,basis,ee,er) loop
    actual:=app.ph_contribution_candidate(r.agency,r.basis,'2025-01-01');
    perform pg_temp.check_contrib((actual->>'employee')::numeric=r.ee and
      (actual->>'employer')::numeric=r.er and (actual->>'total')::numeric=r.ee+r.er,
      r.agency||' '||r.basis);
    n:=n+1;
  end loop;
  raise notice '% agency reference cases passed',n;
end $$;
select pg_temp.invalid_contrib('sss',1,'2024-12-01');
select pg_temp.invalid_contrib('philhealth',1,'2026-12-01');
select pg_temp.check_contrib((app.ph_contribution_candidate('philhealth',1,'2026-01-01')->>'total')::numeric=500,'2026 floor confirmed');
select pg_temp.check_contrib((app.ph_contribution_candidate('philhealth',100001,'2026-11-01')->>'total')::numeric=5000,'2026 ceiling confirmed');
select pg_temp.invalid_contrib('pagibig',1,'2024-01-01');
select pg_temp.invalid_contrib('pagibig',1,'2026-12-01');
select pg_temp.invalid_contrib('sss',1,'2025-01-02');
select pg_temp.invalid_contrib('sss',0,'2025-01-01');
select pg_temp.invalid_contrib('sss',-1,'2025-01-01');
select pg_temp.invalid_contrib('sss','NaN','2025-01-01');
select pg_temp.invalid_contrib('sss','Infinity','2025-01-01');
select pg_temp.invalid_contrib('sss','-Infinity','2025-01-01');
select pg_temp.invalid_contrib('sss',1.001,'2025-01-01');
select pg_temp.invalid_contrib('sss',1000000001,'2025-01-01');
select pg_temp.invalid_contrib('sss',null,'2025-01-01');
select pg_temp.invalid_contrib(null,1,'2025-01-01');
select pg_temp.invalid_contrib('invalid',1,'2025-01-01');
select pg_temp.invalid_contrib('sss',1,null);
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated','service_role'] loop
    perform pg_temp.check_contrib(not has_function_privilege(r,'app.ph_contribution_candidate(text,numeric,date)','EXECUTE'),'private: '||r);
  end loop;
  raise notice 'contribution invalid input and API grant checks passed';
end $$;
rollback;
