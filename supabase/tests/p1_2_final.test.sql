\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(12,'semi-monthly','2026-02-01','daily',700,false,'none',true);
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_cutoff_2026(pg_temp.org9(12),pg_temp.u(2),'2026-02-01');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select app.ph_post_benefit(pg_temp.org9(12),pg_temp.u(2),'fixture-final-13th','2026-02-28','13th_month',1166.67,null,null,'fixture independently reviewed final thirteenth');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_cutoff_2026(pg_temp.org9(12),pg_temp.u(2),'2026-02-16');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
insert into app.ph_employment_history values(pg_temp.org9(12),pg_temp.u(2),'2026-03-01','2026-03-01Z','separated',null,null,null,null,'fictional reviewed resignation',pg_temp.u(1));
select public.offboard_member((select id from public.memberships where organization_id=pg_temp.org9(12) and user_id=pg_temp.u(2)));
select pg_temp.attest(pg_temp.org9(12),'cutoff_final','2026-02-16','{"reason":"termination","exitKind":"ordinary_resignation_no_severance","undispatched":true,"completeExitEntitlements":true,"rankAndFileEligible":true,"available":0}');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.denied($$select app.ph_record_annual_settlement_2026(pg_temp.org9(12),pg_temp.u(2),'2026-02-16')$$,'42501','maker cannot finalize cutoff');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.expect((app.ph_record_annual_settlement_2026(pg_temp.org9(12),pg_temp.u(2),'2026-02-16')->>'refund')::numeric=(select sum(withholding) from app.ph_effective_monetary where organization_id=pg_temp.org9(12)),'final cutoff refund reconciles effective YTD withholding');
select pg_temp.expect((select final_revision=1 from app.ph_annual_settlement where organization_id=pg_temp.org9(12)),'settlement binds effective revision');
select pg_temp.attest(pg_temp.org9(12),'settlement_journal','2026-02-16',jsonb_build_object('treatment','reviewed-recoverable-and-payable-accrual','result',(select result from app.ph_annual_settlement where organization_id=pg_temp.org9(12))));
select app.ph_post_annual_journal(pg_temp.org9(12),pg_temp.u(2),2026);
select pg_temp.expect((select debit_total=credit_total and debit_total>0 from app.ph_annual_journal where organization_id=pg_temp.org9(12)),'final refund journal balanced');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select app.ph_prepare_month_report(pg_temp.org9(12),'2026-02-01','fictional complete month after settlement');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_review_month_report(pg_temp.org9(12),'2026-02-01','fictional independent review');
select pg_temp.expect((select (totals->>'bir')::numeric=(select sum(withholding) from app.ph_effective_monetary where organization_id=pg_temp.org9(12)) from app.ph_month_report where organization_id=pg_temp.org9(12)),'refund not silently offset from BIR report');
rollback;
