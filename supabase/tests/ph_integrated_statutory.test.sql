\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
-- Owner is importer; payroll user is independent reviewer.
select app.ph_open_benefit_year(pg_temp.org(),pg_temp.u(2),'2026-01-05','{"cba_productivity:2026":11900}',89500,'monthly','reviewed fictional opening balances');
select pg_temp.expect((app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'benefit-0001','2026-01-06','rice',2400,null,null,'receipt 1')->>'taxable')::numeric=0,'rice first payment');
select pg_temp.expect((app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'benefit-0002','2026-01-06','rice',700,null,null,'receipt 2')->>'taxable')::numeric=100,'rice monthly and shared annual excess');
select pg_temp.expect((app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'benefit-0002','2026-01-06','rice',700,null,null,'receipt 2')->>'taxable')::numeric=100,'retry reproduces result');
select pg_temp.expect((select count(*)=2 from app.ph_benefit_event),'retry cannot consume benefit twice');
select pg_temp.denied($$select app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'benefit-0002','2026-01-06','rice',701,null,null,'receipt 2')$$,'22023','conflicting event key');
select pg_temp.expect((app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'benefit-0003','2026-01-07','productivity',200,null,null,'fixture')->>'taxable')::numeric=100,'CBA and productivity share opening bucket');
select pg_temp.expect((app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'benefit-0004','2026-02-01','rice',2500,null,null,'fixture')->>'taxable')::numeric=0,'new month bucket');
select pg_temp.expect((app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'benefit-0005','2026-02-02','dependent_medical',400,null,null,'fixture')->>'taxable')::numeric=67,'fixed monthly medical mode');
select pg_temp.denied($$select app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'benefit-0006','2026-01-08','rice',100,null,null,'fixture')$$,'22023','retroactive event fails closed');
select pg_temp.denied($$update app.ph_benefit_event set result='{}'$$,'42501','benefit history immutable');
create temp table cert(id uuid,name text);
insert into cert select app.ph_import_2316(pg_temp.org(),pg_temp.u(2),2026,'issuer-A-001',repeat('a',64),'2026-01-01','2026-02-28',
'{"19":110000,"20":10000,"21":100000,"22":0,"23":100000,"24":0,"25A":10000,"25B":0,"26":10000,"27":0,"28":10000,"34":10000,"38":10000,"52":100000}','fictional signed source A'),'a';
select pg_temp.denied($$select app.ph_review_2316(pg_temp.org(),(select id from cert where name='a'),true,'self review')$$,'42501','importer cannot approve');
select pg_temp.denied($$select app.ph_annual_from_verified_2316(pg_temp.org(),pg_temp.u(2),'2026-11-24','2026-12-15','year_end',300000,10000,5000,'2026-05-01','fixture completeness')$$,'P0001','pending form blocks annualization');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_review_2316(pg_temp.org(),(select id from cert where name='a'),true,'independent fictional document review A');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
insert into cert select app.ph_import_2316(pg_temp.org(),pg_temp.u(2),2026,'issuer-B-001',repeat('b',64),'2026-03-01','2026-04-30',
'{"19":110000,"20":10000,"21":100000,"22":100000,"23":200000,"24":0,"25A":10000,"25B":10000,"26":20000,"27":0,"28":20000,"34":10000,"38":10000,"52":100000}','fictional signed source B'),'b';
select pg_temp.expect((select id=app.ph_import_2316(pg_temp.org(),pg_temp.u(2),2026,'issuer-B-001',repeat('b',64),'2026-03-01','2026-04-30',
'{"19":110000,"20":10000,"21":100000,"22":100000,"23":200000,"24":0,"25A":10000,"25B":10000,"26":20000,"27":0,"28":20000,"34":10000,"38":10000,"52":100000}','fictional signed source B') from cert where name='b'),'document retry idempotent');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_review_2316(pg_temp.org(),(select id from cert where name='b'),true,'independent fictional document review B');
do $$ declare j jsonb; begin
j:=app.ph_annual_from_verified_2316(pg_temp.org(),pg_temp.u(2),'2026-11-24','2026-12-15','year_end',300000,10000,5000,'2026-05-01','fixture completeness');
perform pg_temp.expect((j->>'previousTaxable')::numeric=200000 and (j->>'previousWithheld')::numeric=20000 and (j->>'taxDue')::numeric=42500 and (j->>'employerAdvance')::numeric=7500,'successive certificates count present employer only, no double counting');
end $$;
select pg_temp.denied($$select app.ph_annual_from_verified_2316(pg_temp.org(),pg_temp.u(2),'2026-11-24','2026-12-15','year_end',300000,10000,5000,'2026-04-01','fixture completeness')$$,'P0001','concurrent employer period rejected');
select pg_temp.denied($$update app.ph_2316_review set approved=false$$,'42501','review immutable');
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select pg_temp.denied($$select app.ph_post_benefit(pg_temp.org(),pg_temp.u(2),'benefit-9999','2026-03-01','rice',1,null,null,'fixture')$$,'42501','unauthorized role denied');
select pg_temp.denied($$select app.ph_annual_from_verified_2316(pg_temp.org(),pg_temp.u(2),'2026-11-24','2026-12-15','year_end',300000,10000,5000,'2026-05-01','fixture completeness')$$,'42501','unauthorized certificate totals denied');
do $$ declare r text; t text; begin
foreach r in array array['anon','authenticated','service_role'] loop
 foreach t in array array['ph_benefit_year','ph_benefit_event','ph_2316_import','ph_2316_review'] loop
 perform pg_temp.expect(not has_table_privilege(r,'app.'||t,'SELECT,INSERT,UPDATE,DELETE'),'private '||r||' '||t);
 end loop;
 perform pg_temp.expect(not has_function_privilege(r,'app.ph_post_benefit(uuid,uuid,text,date,text,numeric,numeric,numeric,text)','EXECUTE'),'private benefit function');
 perform pg_temp.expect(not has_function_privilege(r,'app.ph_review_2316(uuid,uuid,boolean,text)','EXECUTE'),'private review function');
end loop; end $$;
rollback;
