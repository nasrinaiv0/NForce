\set ON_ERROR_STOP on
begin;
create function pg_temp.ok(b boolean,l text) returns void language plpgsql as $$ begin if b is distinct from true then raise exception 'FAIL %',l; end if; end $$;
create function pg_temp.reject(q text) returns void language plpgsql as $$ begin execute q; raise exception 'unexpected success'; exception when sqlstate '22023' then null; end $$;
do $$ declare r record; j jsonb; n int:=0;
begin
for r in select * from (values
('rice',2500),('laundry',400),('uniform',8000),('medical_assistance',12000),('achievement_award',12000),('christmas_anniversary_gift',6000),('cba',12000),('productivity',12000)) v(code,cap) loop
  j:=app.ph_compensation_classify('2026-06-01',r.code,r.cap+100,0,89950,false,'fixture');
  perform pg_temp.ok((j->>'deMinimisExempt')::numeric=r.cap and (j->>'otherBenefitsExempt')::numeric=50 and (j->>'taxable')::numeric=50,r.code||' ceiling');
  j:=app.ph_compensation_classify('2026-06-01',r.code,100,r.cap-50,0,false,'fixture');
  perform pg_temp.ok((j->>'deMinimisExempt')::numeric=50 and (j->>'bucketUsage')::numeric=r.cap+50,r.code||' prior usage');
  n:=n+2;
end loop;
raise notice '% monetary benefit cases passed',n;
end $$;
select pg_temp.ok((app.ph_compensation_classify('2026-06-01','dependent_medical',400,0,90000,false,'fixture',null,null,'monthly')->>'taxable')::numeric=67,'medical monthly');
select pg_temp.ok((app.ph_compensation_classify('2026-06-01','dependent_medical',2200,0,90000,false,'fixture',null,null,'semester')->>'taxable')::numeric=200,'medical semester');
select pg_temp.ok((app.ph_compensation_classify('2026-06-01','vacation_conversion',1200,11,90000,false,'fixture',2)->>'taxable')::numeric=600,'vacation days');
select pg_temp.ok((app.ph_compensation_classify('2026-06-01','ot_night_meal',200,0,90000,false,'fixture',null,540)->>'taxable')::numeric=38,'meal wage');
select pg_temp.ok((app.ph_compensation_classify('2026-06-01','13th_month',20000,0,80000,false,'fixture')->>'taxable')::numeric=10000,'other benefits shared ceiling');
select pg_temp.ok((app.ph_compensation_classify('2026-06-01','cba',10,0,0,false,'fixture')->>'bucket')=(app.ph_compensation_classify('2026-06-01','productivity',10,0,0,false,'fixture')->>'bucket'),'shared CBA/productivity');
do $$ declare c text; begin
foreach c in array array['basic','holiday','overtime','night_differential','qualifying_hazard'] loop
perform pg_temp.ok((app.ph_compensation_classify('2026-06-01',c,100,0,0,true,'fixture')->>'taxable')::numeric=0,'MWE '||c);
perform pg_temp.ok((app.ph_compensation_classify('2026-06-01',c,100,0,0,false,'fixture')->>'taxable')::numeric=100,'non-MWE '||c);
end loop;
foreach c in array array['commission','taxable_allowance','other_taxable','nonqualifying_hazard'] loop
perform pg_temp.ok((app.ph_compensation_classify('2026-06-01',c,100,0,0,true,'fixture')->>'taxable')::numeric=100,'taxable MWE '||c);
end loop;
end $$;
select pg_temp.ok((app.ph_annual_adjustment('2026-11-24','2026-12-15','year_end',300000,200000,10000,20000,5000,'2316 fixture')->>'taxDue')::numeric=42500,'annual combined');
select pg_temp.ok((app.ph_annual_adjustment('2026-11-24','2026-12-15','year_end',300000,200000,10000,20000,5000,'2316 fixture')->>'employerAdvance')::numeric=7500,'insufficient final pay');
select pg_temp.ok((app.ph_annual_adjustment('2026-11-24','2026-12-15','year_end',200000,0,5000,0,10000,'fixture')->>'refund')::numeric=5000,'refund');
select pg_temp.ok(app.ph_annual_adjustment('2026-11-24','2026-12-15','year_end',200000,0,5000,0,10000,'fixture')->>'refundDue'='2027-01-25','refund deadline');
select pg_temp.ok(app.ph_annual_adjustment('2026-11-24','2026-11-24','termination',200000,0,5000,0,10000,'fixture')->>'refundDue'='2026-11-24','termination refund');
select pg_temp.reject($$select app.ph_compensation_classify('2026-01-05','rice',100,0,0,false,'fixture')$$);
select pg_temp.reject($$select app.ph_compensation_classify('2026-06-01','unknown',100,0,0,false,'fixture')$$);
select pg_temp.reject($$select app.ph_compensation_classify('2026-06-01','basic',100,0,0,true,'')$$);
select pg_temp.reject($$select app.ph_compensation_classify('2026-06-01','dependent_medical',100,0,0,false,'fixture')$$);
select pg_temp.reject($$select app.ph_compensation_classify('2026-06-01','ot_night_meal',100,0,0,false,'fixture')$$);
select pg_temp.reject($$select app.ph_annual_adjustment('2026-11-24','2026-11-24','year_end',200000,0,5000,0,10000,'fixture')$$);
do $$ declare r text; begin foreach r in array array['anon','authenticated','service_role'] loop
perform pg_temp.ok(not has_function_privilege(r,'app.ph_compensation_classify(date,text,numeric,numeric,numeric,boolean,text,numeric,numeric,text)','EXECUTE'),'private classifier');
perform pg_temp.ok(not has_function_privilege(r,'app.ph_annual_adjustment(date,date,text,numeric,numeric,numeric,numeric,numeric,text)','EXECUTE'),'private annualization');
end loop; raise notice 'PH compensation classification, MWE, annualization and private grant cases passed'; end $$;
rollback;
