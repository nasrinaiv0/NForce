\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
select pg_temp.expect((app.ph_thirteenth_amount(228010.04,0,0,0,true,'DOLE example')->>'minimum')::numeric=19000.84,'DOLE 2026 example A');
select pg_temp.expect((app.ph_thirteenth_amount(235560.04,0,0,0,true,'DOLE example')->>'minimum')::numeric=19630,'DOLE 2026 example C');
select pg_temp.expect((app.ph_thirteenth_amount(177236.28,0,0,0,true,'DOLE example')->>'minimum')::numeric=14769.69,'DOLE 2026 departed example');
select pg_temp.expect((app.ph_thirteenth_amount(240000,23000,1000,10000,true,'reviewed fixture')->>'remaining')::numeric=12000,'maternity differential and integrated basic included; paid deducted');
select pg_temp.denied($$select app.ph_thirteenth_amount(100,0,0,0,false,'reviewed fixture')$$,'22023','eligibility required');
select pg_temp.expect((app.ph_maternity_amount('live_birth',false,100000,7000,70000,true,'reviewed fixture')->>'salaryDifferential')::numeric=23000,'maternity differential after employee premiums');
select pg_temp.expect((app.ph_maternity_amount('live_birth',true,120000,7000,80000,true,'reviewed fixture')->>'paidDays')::int=120,'solo parent maternity');
select pg_temp.expect((app.ph_maternity_amount('miscarriage',false,60000,4000,40000,true,'reviewed fixture')->>'paidDays')::int=60,'miscarriage');
select pg_temp.expect((app.ph_maternity_amount('live_birth',false,50000,3000,70000,true,'reviewed fixture')->>'salaryDifferential')::numeric=0,'no negative maternity differential');
select pg_temp.expect((app.ph_leave_amount('sil',2,3,600,12,null,true,'reviewed fixture')->>'paidAmount')::numeric=1800,'SIL remaining paid days');
select pg_temp.expect((app.ph_leave_amount('solo_parent',0,7,600,6,null,true,'reviewed fixture')->>'paidAmount')::numeric=4200,'solo parent six months');
select pg_temp.expect((app.ph_leave_amount('paternity',0,7,600,1,4,true,'reviewed fixture')->>'cashConversionCandidate')::boolean=false,'paternity not convertible');
select pg_temp.expect((app.ph_leave_amount('vawc',0,10,600,1,null,true,'reviewed fixture')->>'paidAmount')::numeric=6000,'VAWC minimum cap');
select pg_temp.denied($$select app.ph_leave_amount('sil',0,5,600,11,null,true,'reviewed fixture')$$,'22023','SIL service eligibility');
select pg_temp.denied($$select app.ph_leave_amount('paternity',0,7,600,12,5,true,'reviewed fixture')$$,'22023','fifth delivery needs separate review');
select pg_temp.denied($$select app.ph_leave_amount('vawc',9,2,600,12,null,true,'reviewed fixture')$$,'22023','extension requires review');
select pg_temp.expect(app.ph_special_women_leave(30000,2,6,true,'reviewed fixture')=60000,'two months special leave');
select pg_temp.expect((app.ph_separation_amount('retrenchment',30000,30,true,'reviewed fixture')->>'minimum')::numeric=45000,'half month and rounded service');
select pg_temp.expect((app.ph_separation_amount('redundancy',30000,30,true,'reviewed fixture')->>'minimum')::numeric=90000,'full month redundancy');
select pg_temp.expect((app.ph_separation_amount('disease',30000,4,true,'reviewed fixture')->>'minimum')::numeric=30000,'one month floor');
select pg_temp.denied($$select app.ph_separation_amount('resignation',30000,30,true,'reviewed fixture')$$,'22023','unsupported separation cause');
select pg_temp.expect((app.ph_retirement_amount(600,66,60,true,'reviewed fixture')->>'minimum')::numeric=81000,'22.5-day retirement floor');
select pg_temp.denied($$select app.ph_retirement_amount(600,59,60,true,'reviewed fixture')$$,'22023','five actual years before rounding');
select pg_temp.denied($$select app.ph_retirement_amount('NaN',66,60,true,'reviewed fixture')$$,'22023','nonfinite rejected');
do $$ declare a text; j jsonb; target jsonb; ee numeric;er numeric; n int:=0;begin
foreach a in array array['sss','philhealth','pagibig'] loop
target:=app.ph_contribution_candidate(a,30000,'2026-11-01');
for n in 1..31 loop
 select sum((q->>'employee')::numeric),sum((q->>'employer')::numeric) into ee,er
 from (select app.ph_cutoff_contribution(a,30000,'2026-11-01',n,i) q from generate_series(1,n)i) x;
 perform pg_temp.expect(ee=(target->>'employee')::numeric and er=(target->>'employer')::numeric,'contribution allocation '||a||' '||n);
end loop;end loop;end $$;
insert into app.ph_employment_history values(pg_temp.org(),pg_temp.u(2),'2026-01-01','2026-01-01Z','employed','daily',600,'site','wage','fictional MWE history',pg_temp.u(1));
select app.ph_open_benefit_year(pg_temp.org(),pg_temp.u(2),'2026-01-05','{}',90000,'monthly','reviewed fictional opening');
select app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'benefit-2026-001','2026-01-15','rice',3000,null,null,'fixture benefit');
do $$ declare j jsonb;begin
j:=app.ph_2026_cutoff_quote(pg_temp.org(),pg_temp.u(2),'2026-01-15','2026-01-15','2026-01-15','daily',600,150,0,2000,true,600,30000,30000,30000,20,1,0,0,0,1,false,'reviewed fixture');
perform pg_temp.expect((j->>'gross')::numeric=5750 and (j->>'taxable')::numeric=2500 and (j->>'withholding')::numeric=357.85 and (j->>'net')::numeric=5269.65,'daily MWE mixed taxable and ledger benefits');
j:=app.ph_2026_cutoff_quote(pg_temp.org(),pg_temp.u(2),'2026-01-01','2026-01-15','2026-01-15','semi-monthly',9000,150,0,4000,true,600,30000,30000,30000,2,1,0,0,0,1,false,'reviewed fixture');
perform pg_temp.expect((j->>'net')::numeric=14925 and (j->>'taxable')::numeric=4500 and (j->>'benefitTaxable')::numeric=500,'semi-monthly quote reuses existing benefit event');
perform pg_temp.expect((select count(*)=1 from app.ph_benefit_event where organization_id=pg_temp.org()),'quote never consumes benefit twice');
end $$;
select pg_temp.denied($$select app.ph_2026_cutoff_quote(pg_temp.org(),pg_temp.u(2),'2026-01-01','2026-01-15','2026-01-15','semi-monthly',9000,150,0,4000,false,600,30000,30000,30000,2,1,0,0,0,1,false,'reviewed fixture')$$,'P0001','MWE cannot be silently reclassified');
-- Non-MWE rate revision; taxable ordinary wages and all allocated employee deductions.
insert into app.ph_employment_history values(pg_temp.org(),pg_temp.u(2),'2026-02-01','2026-02-01Z','employed','daily',700,'site','wage','fictional revised daily rate',pg_temp.u(1));
do $$ declare j jsonb; begin
j:=app.ph_2026_cutoff_quote(pg_temp.org(),pg_temp.u(2),'2026-02-01','2026-02-15','2026-02-15','semi-monthly',10000,0,0,5000,false,600,30000,30000,30000,2,1,1225,0,0,1,false,'reviewed fixture');
perform pg_temp.expect((j->>'gross')::numeric=15000 and (j->>'taxable')::numeric=13775 and (j->>'withholding')::numeric=503.70 and (j->>'net')::numeric=13271.30,'non-MWE semi-monthly quote');
end $$;
select pg_temp.denied($$select app.ph_2026_cutoff_quote('fb100000-0000-0000-0000-000000000099',pg_temp.u(2),'2026-02-01','2026-02-15','2026-02-15','semi-monthly',10000,0,0,5000,false,600,30000,30000,30000,2,1,1225,0,0,1,false,'reviewed fixture')$$,'42501','cross-tenant quote denied');
\ir ph_month_fixture.sql
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_month(pg_temp.mo(),pg_temp.u(2),'2025-01-01');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select app.ph_propose_reversal(pg_temp.mo(),pg_temp.u(2),'2025-01-01','fictional correction','reviewed unsent accrual');
select pg_temp.denied($$select app.ph_approve_reversal(pg_temp.mo(),pg_temp.u(2),'2025-01-01','self review')$$,'42501','reversal maker denied');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_approve_reversal(pg_temp.mo(),pg_temp.u(2),'2025-01-01','independent review');
select app.ph_approve_reversal(pg_temp.mo(),pg_temp.u(2),'2025-01-01','independent review');
select pg_temp.expect((select count(*)=1 from app.ph_money_reversal),'one reversal');
select pg_temp.expect((select count(*)=9 and sum(debit)=34338.22 and sum(credit)=34338.22 from app.ph_money_reversal_journal),'balanced inverse journal');
select pg_temp.expect(not exists(select 1 from app.ph_money_journal j join app.ph_money_reversal_journal r using(organization_id,user_id,pay_month,account_code) where j.debit<>r.credit or j.credit<>r.debit),'all original lines exactly inverted');
select pg_temp.denied($$select app.ph_post_month(pg_temp.mo(),pg_temp.u(2),'2025-01-01')$$,'P0001','reversed snapshot cannot be reposted');
select pg_temp.denied($$delete from app.ph_money_reversal_journal$$,'42501','reversal journal immutable');
do $$ declare r text;begin
foreach r in array array['anon','authenticated','service_role'] loop
perform pg_temp.expect(not has_table_privilege(r,'app.ph_money_reversal','SELECT,INSERT,UPDATE,DELETE'),'private reversal');
perform pg_temp.expect(not has_function_privilege(r,'app.ph_approve_reversal(uuid,uuid,date,text)','EXECUTE'),'private reversal approval');
perform pg_temp.expect(not has_function_privilege(r,'app.ph_2026_cutoff_quote(uuid,uuid,date,date,date,text,numeric,numeric,numeric,numeric,boolean,numeric,numeric,numeric,numeric,int,int,numeric,numeric,numeric,int,boolean,text)','EXECUTE'),'private cutoff quote');
end loop;end $$;
rollback;
