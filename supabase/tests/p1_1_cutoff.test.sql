\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
-- Fictional exact-locked source fixtures, independent of monetary arithmetic.
-- The inherited PR12 suite exercises actual attendance replay and approval.
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(1,'daily','2026-09-15','daily',540,true,'rice');
select pg_temp.seed9(3,'semi-monthly','2026-02-01','daily',700,false,'none');
select pg_temp.seed9(4,'semi-monthly','2026-02-16','daily',700,false,'none');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.denied($$select app.ph_post_cutoff_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')$$,'42501','period maker cannot post');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')->>'net')::numeric=4397.55,'daily MWE from locked work and benefit evidence');
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(3),pg_temp.u(2),'2026-02-01')->>'gross')::numeric=7000,'semi-monthly exact historical wages');
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(4),pg_temp.u(2),'2026-02-16')->>'gross')::numeric=7000,'complete final semi-monthly cutoff');
select pg_temp.expect((select count(*)=3 from app.ph_monetary_snapshot),'two frequencies same physical ledger');
select pg_temp.denied($$select app.ph_prepare_month_report(pg_temp.org9(3),'2026-02-01','fictional incomplete report')$$,'P0001','incomplete cutoff month cannot be reported');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select app.ph_prepare_month_report(pg_temp.org9(4),'2026-02-01','fictional complete cutoff report');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_review_month_report(pg_temp.org9(4),'2026-02-01','fictional independent report review');
select pg_temp.expect((select (totals->>'sss')::numeric=4530 and (totals->>'philhealth')::numeric=1500 and (totals->>'pagibig')::numeric=400 from app.ph_month_report where organization_id=pg_temp.org9(4)),'complete cutoff report reconciles three agencies');
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')->>'net')::numeric=4397.55,'same cutoff idempotent');
select pg_temp.denied($$select app.ph_post_benefit(pg_temp.org9(1),pg_temp.u(2),'late-p11-benefit','2026-09-15','rice',1,null,null,'fixture late event')$$,'42501','late benefit denied');
select pg_temp.denied($$insert into app.ph_monetary_snapshot(organization_id,period_start,user_id,pay_date,gross,employee_contributions,employer_contributions,taxable,withholding,net,evidence,posted_by,frequency,tax_deductible) values(pg_temp.org9(3),'2026-02-02',pg_temp.u(2),'2026-02-02',0,0,0,0,0,0,'{}',pg_temp.u(4),'daily',0)$$,'P0001','overlapping frequency denied');
select pg_temp.attest(pg_temp.org9(1),'reversal','2026-09-15','{"undispatched":true,"reason":"fictional supplemental correction"}');
select app.ph_post_canonical_reversal(pg_temp.org9(1),pg_temp.u(2),'2026-09-15');
select pg_temp.expect((select debit_total=credit_total and debit_total=4540 from app.ph_canonical_reversal),'inverse journal balances');
select pg_temp.expect(not exists(select 1 from app.ph_canonical_reversal r join app.ph_payroll_journal j using(organization_id,period_start,user_id) cross join lateral jsonb_array_elements(r.lines)x join lateral jsonb_array_elements(j.lines)y on x->>'account'=y->>'account' where (x->>'debit')::numeric<>(y->>'credit')::numeric or (x->>'credit')::numeric<>(y->>'debit')::numeric),'exact inverse of original journal');
select pg_temp.denied($$select app.ph_post_cutoff_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')$$,'P0001','reversed cutoff blocked pending replay');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_post_cutoff_2026(uuid,uuid,date)','EXECUTE'),'private cutoff posting');
select pg_temp.expect(not has_table_privilege('authenticated','app.ph_canonical_reversal','SELECT'),'private reversal');

select pg_temp.attest(pg_temp.org9(1),'replay','2026-09-15',
 (select a.payload||jsonb_build_object('taxableExtras',1200,'reason','correct fictional supplement','undispatched',true,'originalAttestation',a.id) from app.ph_payroll_attestation a where a.organization_id=pg_temp.org9(1) and a.kind='period'));
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.denied($$select app.ph_replay_cutoff_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')$$,'42501','replay maker denied');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.expect((app.ph_replay_cutoff_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')->>'net')::numeric=4557.55,'same-engine corrected cutoff net');
select pg_temp.expect((select count(*)=2 from app.ph_monetary_snapshot where organization_id=pg_temp.org9(1)),'two immutable revisions in original ledger');
select pg_temp.expect((select count(*)=1 and max(revision)=2 from app.ph_effective_monetary where organization_id=pg_temp.org9(1)),'effective revision only');
select pg_temp.expect((app.ph_replay_cutoff_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')->>'net')::numeric=4557.55,'replacement retry idempotent');
select pg_temp.expect((select sum(debit_total-credit_total)=0 from app.ph_payroll_journal where organization_id=pg_temp.org9(1)),'replacement and original journals balanced');
select pg_temp.denied($$select app.ph_post_cutoff_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')$$,'P0001','ordinary retry cannot return superseded original');
select pg_temp.expect((app.ph_export_reviewed_month(pg_temp.org9(4),'2026-02-01')->>'officialFiling')::boolean=false,'internal export is not official filing');
select pg_temp.expect((app.ph_export_reviewed_month(pg_temp.org9(4),'2026-02-01')->>'csv') like '%2026-02,sss,4530.00,0.00,4530.00%','CSV contains reviewed SSS liability');
select pg_temp.expect((app.ph_export_reviewed_month(pg_temp.org9(4),'2026-02-01')->>'sha256')=encode(sha256(convert_to(app.ph_export_reviewed_month(pg_temp.org9(4),'2026-02-01')->>'csv','UTF8')),'hex'),'export hash matches bytes');
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select pg_temp.denied($$select app.ph_export_reviewed_month(pg_temp.org9(4),'2026-02-01')$$,'42501','staff export denied');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_replay_cutoff_2026(uuid,uuid,date)','EXECUTE'),'replay stays private');
select pg_temp.expect(not has_table_privilege('authenticated','app.ph_effective_monetary','SELECT'),'effective ledger private');
rollback;

