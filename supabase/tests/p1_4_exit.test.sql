\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(18,'monthly','2026-02-01','monthly',30000,false,'13th');
select pg_temp.seed9(19,'monthly','2026-02-01','monthly',30000,false,'13th');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_cutoff_2026(pg_temp.org9(18),pg_temp.u(2),'2026-02-01');
select app.ph_post_cutoff_2026(pg_temp.org9(19),pg_temp.u(2),'2026-02-01');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
insert into app.ph_employment_history values(pg_temp.org9(18),pg_temp.u(2),'2026-03-01','2026-03-01Z','separated',null,null,null,null,'fictional reviewed separation',pg_temp.u(1)),(pg_temp.org9(19),pg_temp.u(2),'2026-03-01','2026-03-01Z','separated',null,null,null,null,'fictional reviewed retirement',pg_temp.u(1));
select public.offboard_member(id) from public.memberships where organization_id in (pg_temp.org9(18),pg_temp.org9(19)) and user_id=pg_temp.u(2);
select pg_temp.attest(pg_temp.org9(18),'statutory_quote','2026-03-01','{"category":"separation","cause":"redundancy","monthlyBase":30000,"serviceMonths":30,"eligible":true}');
select pg_temp.attest(pg_temp.org9(19),'statutory_quote','2026-03-01','{"category":"retirement","dailyBase":600,"serviceMonths":66,"age":60,"eligible":true}');
select pg_temp.attest(pg_temp.org9(18),'statutory_accrual','2026-03-01',jsonb_build_object('category','separation','quoteDate','2026-03-01','quoteId',(select id from app.ph_payroll_attestation where organization_id=pg_temp.org9(18) and kind='statutory_quote'),'sourceDigest',repeat('e',64),'taxTreatmentVerified',true,'noDuplicateCompensation',true,'statutoryMinimumOnly',true,'taxExemptionVerified',true,'taxEvidenceReference','fictional independent tax evidence','exitDate','2026-03-01','finalPeriod','2026-02-01','finalRevision',1,'approvedEntitlement',90000));
select pg_temp.expect((app.ph_post_statutory_journal(pg_temp.org9(18),pg_temp.u(2),'2026-03-01','statutory_accrual')->>'amount')::numeric=90000,'reviewed separation accrual');
select pg_temp.attest(pg_temp.org9(19),'statutory_accrual','2026-03-01',jsonb_build_object('category','retirement','quoteDate','2026-03-01','quoteId',(select id from app.ph_payroll_attestation where organization_id=pg_temp.org9(19) and kind='statutory_quote'),'sourceDigest',repeat('f',64),'taxTreatmentVerified',true,'noDuplicateCompensation',true,'statutoryMinimumOnly',true,'taxExemptionVerified',true,'taxEvidenceReference','fictional independent tax evidence','exitDate','2026-03-01','finalPeriod','2026-02-01','finalRevision',1,'approvedEntitlement',81000));
select pg_temp.expect((app.ph_post_statutory_journal(pg_temp.org9(19),pg_temp.u(2),'2026-03-01','statutory_accrual')->>'amount')::numeric=81000,'reviewed retirement accrual');
select pg_temp.expect((select sum(debit_total)=171000 and sum(credit_total)=171000 from app.ph_statutory_journal),'exit journals balanced');
select pg_temp.denied($$select app.ph_post_canonical_reversal(pg_temp.org9(18),pg_temp.u(2),'2026-02-01')$$,'P0001','exit blocks ordinary reversal');

-- Existing exit journals are linked into final compensation without a second accrual.
select pg_temp.attest(pg_temp.org9(18),'cutoff_final','2026-02-01',jsonb_build_object('reason','termination','exitKind','separation','undispatched',true,'completeExitEntitlements',true,'rankAndFileEligible',true,'available',0,'statutoryAttestationId',(select attestation_id from app.ph_statutory_journal where organization_id=pg_temp.org9(18))));
select pg_temp.expect((app.ph_record_annual_settlement_2026(pg_temp.org9(18),pg_temp.u(2),'2026-02-01')->'finalCompensationCandidate'->>'combinedAccrualCandidate')::numeric=120050,'separation and ordinary final compensation reconcile');
select pg_temp.attest(pg_temp.org9(19),'cutoff_final','2026-02-01',jsonb_build_object('reason','termination','exitKind','retirement','undispatched',true,'completeExitEntitlements',true,'rankAndFileEligible',true,'available',0,'statutoryAttestationId',(select attestation_id from app.ph_statutory_journal where organization_id=pg_temp.org9(19))));
select pg_temp.expect((app.ph_record_annual_settlement_2026(pg_temp.org9(19),pg_temp.u(2),'2026-02-01')->'finalCompensationCandidate'->>'combinedAccrualCandidate')::numeric=111050,'retirement and ordinary final compensation reconcile');
select pg_temp.expect((select count(*)=2 from app.ph_statutory_journal),'final reconciliation does not duplicate exit journal');
select pg_temp.attest(pg_temp.org9(18),'settlement_journal','2026-02-01',jsonb_build_object('treatment','reviewed-recoverable-and-payable-accrual','result',(select result from app.ph_annual_settlement where organization_id=pg_temp.org9(18))));
select app.ph_post_annual_journal(pg_temp.org9(18),pg_temp.u(2),2026);
select pg_temp.expect((select debit_total=1007.55 and credit_total=1007.55 from app.ph_annual_journal where organization_id=pg_temp.org9(18)),'annual journal only accrues refund not exit again');
select pg_temp.denied($$select app.ph_month_report_totals(pg_temp.org9(18),'2026-03-01')$$,'P0001','exit report requires classified payment integration');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_statutory_compensation_summary(uuid,uuid,int)','EXECUTE'),'statutory compensation review private');
rollback;
