\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
-- Exercise PR11's departed path using an exact canonical week (no login restoration).
delete from app.accounting_submission where organization_id=pg_temp.org() and user_id=pg_temp.u(2) and period_start='2025-01-06';
update public.timesheets set status='returned' where organization_id=pg_temp.org() and user_id=pg_temp.u(2) and period_start='2025-01-06';
update public.memberships set status='ended' where organization_id=pg_temp.org() and user_id=pg_temp.u(2);
select app.accounting_prepare_departed(pg_temp.org(),'2025-01-06',pg_temp.u(2),'fictional departed reconciliation');
select pg_temp.denied($$select app.accounting_approve_departed(pg_temp.org(),'2025-01-06',pg_temp.u(2))$$,'42501','departed maker cannot approve');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.accounting_approve_departed(pg_temp.org(),'2025-01-06',pg_temp.u(2));
select app.accounting_lock(pg_temp.org(),'2025-01-06');
select pg_temp.expect((select status='ended' from public.memberships where organization_id=pg_temp.org() and user_id=pg_temp.u(2)),'departed employee stays ended');
select pg_temp.expect((select count(*)=1 from app.accounting_departed_decision where organization_id=pg_temp.org()),'departed decision immutable evidence');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.expect((select count(*)>0 from app.accounting_lifecycle_event where organization_id=pg_temp.org() and user_id=pg_temp.u(2)),'observed lifecycle captured');
select pg_temp.denied($$insert into public.attendance_events(organization_id,user_id,type,occurred_at,source,idempotency_key) values(pg_temp.org(),pg_temp.u(2),'clock_out','2025-01-07 00:00Z','correction','locked-correction-test')$$,'42501','locked correction blocked');
-- Arithmetic oracle, separate from the server-source integration fixture.
select pg_temp.expect(app.ph_cumulative_tax(35000,1,0,'monthly','2025-01-01')->>'withholding'='2208.40','BIR cumulative January');
select pg_temp.expect((app.ph_cumulative_tax(65000,2,2208.40,'monthly','2025-02-01')->>'withholding')::numeric=1291.70,'BIR cumulative February');
select pg_temp.expect((app.ph_cumulative_tax(105000,3,3500.10,'monthly','2025-03-01')->>'withholding')::numeric=3125.10,'BIR cumulative March');
select pg_temp.expect((app.ph_cumulative_tax(10000,2,1000,'monthly','2025-02-01')->>'withholding')::numeric=0,'no negative periodic withholding');
select pg_temp.expect(round(app.ph_monthly_hourly(30000,365,2025),6)=123.287671,'historical divisor 365');
select pg_temp.expect(round(app.ph_monthly_hourly(30000,366,2024),6)=122.950820,'leap-year divisor');
select pg_temp.denied($$select app.ph_monthly_hourly(30000,261,2025)$$,'22023','unsupported divisor rejected');
do $$ declare j jsonb; begin
j:=app.ph_month_amounts(30000,308.22,'2025-01-01',30308.22,30000,30000,0,0,1,false);
perform pg_temp.expect((j->>'gross')::numeric=30308.22 and (j->>'employeeContrib')::numeric=2475 and (j->>'employerContrib')::numeric=4030 and (j->>'withholding')::numeric=1050.03 and (j->>'net')::numeric=26783.19 and (j->>'employerCost')::numeric=34338.22,'independent gross-to-net reference');
end $$;
select pg_temp.denied($$select app.ph_month_amounts(30000,308.22,'2025-01-01',30000,30000,30000,0,0,1,false)$$,'P0001','wrong SSS basis rejected');
select pg_temp.denied($$select app.ph_month_amounts(30000,0,'2026-01-01',30000,30000,30000,0,0,1,false)$$,'22023','unverified year rejected');
-- A distinct fictional tenant with reviewed monthly history and sealed weekly source fixtures.
\ir ph_month_fixture.sql
select pg_temp.denied($$select app.ph_post_month(pg_temp.mo(),pg_temp.u(2),'2025-01-01')$$,'42501','month maker cannot post');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.expect((app.ph_post_month(pg_temp.mo(),pg_temp.u(2),'2025-01-01')->>'net')::numeric=26783.19,'server-derived monthly net');
select pg_temp.expect((app.ph_post_month(pg_temp.mo(),pg_temp.u(2),'2025-01-01')->>'net')::numeric=26783.19,'monetary posting retry stable');
select pg_temp.expect((select count(*)=1 from app.ph_money_snapshot where organization_id=pg_temp.mo()),'one snapshot per employee month');
select pg_temp.expect((select sum(debit)=34338.22 and sum(credit)=34338.22 from app.ph_money_journal where organization_id=pg_temp.mo()),'balanced agency-separated journal');
select pg_temp.denied($$select app.accounting_propose_adjustment(pg_temp.mo(),'2025-01-06',pg_temp.u(2),'REG_OT',-1,'fictional reason for correction','fixture evidence','money-post-guard')$$,'42501','minute adjustment blocked after monetary post');
select pg_temp.denied($$update app.ph_money_snapshot set net=0$$,'42501','money snapshot immutable');
select pg_temp.denied($$delete from app.ph_money_journal$$,'42501','journal immutable');
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select pg_temp.denied($$select app.ph_post_month(pg_temp.mo(),pg_temp.u(2),'2025-01-01')$$,'42501','staff cannot read posted snapshot');
-- No raw documents. Ciphertext placeholder tests only, not a claim of encryption.
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
create temp table cert(id uuid);
insert into cert select app.ph_import_2316(pg_temp.org(),pg_temp.u(2),2026,'issuer-A-001',repeat('a',64),'2026-01-01','2026-02-28',
'{"19":110000,"20":10000,"21":100000,"22":0,"23":100000,"24":0,"25A":10000,"25B":0,"26":10000,"27":0,"28":10000,"34":10000,"38":10000,"52":100000}','fictional source');
select pg_temp.denied($$select app.ph_deposit_2316(pg_temp.org(),(select id from cert),decode(repeat('ab',64),'hex'),repeat('b',64),repeat('a',64),'fake-key-reference','fixture')$$,'22023','custody hash mismatch denied');
select app.ph_deposit_2316(pg_temp.org(),(select id from cert),decode(repeat('ab',64),'hex'),encode(sha256(decode(repeat('ab',64),'hex')),'hex'),repeat('a',64),'fake-key-reference','fictional envelope metadata');
select pg_temp.denied($$select app.ph_verify_2316_custody(pg_temp.org(),(select id from cert),'self review')$$,'42501','custody uploader cannot verify');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_review_2316(pg_temp.org(),(select id from cert),true,'fictional independent form review');
select app.ph_verify_2316_custody(pg_temp.org(),(select id from cert),'fictional external encryption and document attestation');
select pg_temp.expect((select count(*)=1 from app.ph_2316_custody_review),'independent custody review recorded');
do $$ declare r text;t text; begin
foreach r in array array['anon','authenticated','service_role'] loop
 foreach t in array array['ph_2316_custody','ph_2316_custody_review','ph_month_context','ph_month_context_review','ph_money_snapshot','ph_money_journal'] loop
 perform pg_temp.expect(not has_table_privilege(r,'app.'||t,'SELECT,INSERT,UPDATE,DELETE'),'private '||r||' '||t);
 end loop;
 perform pg_temp.expect(not has_function_privilege(r,'app.ph_post_month(uuid,uuid,date)','EXECUTE'),'private monetary posting');
end loop; end $$;
rollback;
