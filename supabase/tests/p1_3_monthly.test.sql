\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(13,'monthly','2026-02-01','monthly',30000,false,'none');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(13),pg_temp.u(2),'2026-02-01')->>'gross')::numeric=30000,'monthly salary guaranteed base');
select pg_temp.expect((select gross=30000 and employee_contributions=2450 and taxable=27550 and net=26542.45 from app.ph_effective_monetary where organization_id=pg_temp.org9(13)),'monthly gross to net');
select pg_temp.attest(pg_temp.org9(13),'reversal','2026-02-01','{"undispatched":true,"reason":"fictional monthly correction"}');
select app.ph_post_canonical_reversal(pg_temp.org9(13),pg_temp.u(2),'2026-02-01');
select pg_temp.attest(pg_temp.org9(13),'replay','2026-02-01',(select a.payload||jsonb_build_object('taxableExtras',1000,'reason','fictional corrected supplement','undispatched',true,'originalAttestation',a.id) from app.ph_payroll_attestation a where a.organization_id=pg_temp.org9(13) and a.kind='period'));
select pg_temp.expect((app.ph_replay_cutoff_2026(pg_temp.org9(13),pg_temp.u(2),'2026-02-01')->>'net')::numeric=27392.45,'monthly revision recomputed');
select pg_temp.expect((select count(*)=1 and max(revision)=2 from app.ph_effective_monetary where organization_id=pg_temp.org9(13)),'monthly effective revision only');
select pg_temp.expect((select sum(debit_total-credit_total)=0 from app.ph_payroll_journal where organization_id=pg_temp.org9(13)),'monthly journals balanced');
-- Reviewed 13th-month accrual uses effective basic, not corrected supplemental income.
select pg_temp.attest(pg_temp.org9(13),'statutory_quote','2026-03-01','{"category":"thirteenth","basic":30000,"maternity":0,"integratedBasic":0,"paid":0,"eligible":true}');
select pg_temp.attest(pg_temp.org9(13),'entitlement','2026-03-01','{"quoteDate":"2026-03-01","category":"thirteenth","payDate":"2026-03-01"}');
select pg_temp.expect((app.ph_settle_reviewed_thirteenth(pg_temp.org9(13),pg_temp.u(2),'2026-03-01')->>'amount')::numeric=2500,'effective monthly basic thirteenth accrual');
select pg_temp.denied($$select app.ph_settle_reviewed_thirteenth(pg_temp.org9(13),pg_temp.u(2),'2026-03-01')$$,'P0001','duplicate statutory accrual denied');
select pg_temp.expect((select count(*)=1 from app.ph_benefit_event where organization_id=pg_temp.org9(13)),'one canonical benefit event');
rollback;
