\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(61,'monthly','2026-02-01','monthly',30000,false,'none');
select pg_temp.seed9(62,'monthly','2026-02-01','monthly',30000,false,'none');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_cutoff_2026(pg_temp.org9(61),pg_temp.u(2),'2026-02-01');
insert into app.accounting_review_access(organization_id,evidence_reference,enabled_by,expires_at) values(pg_temp.org9(61),'fictional scoped review',pg_temp.u(4),now()+interval '1 day');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
select pg_temp.denied($$select public.payroll_self_snapshot(pg_temp.org9(61),'2026-02-01')$$,'P0001','employee cannot see unreleased accrual');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
insert into app.ph_employee_payroll_release(organization_id,period_start,user_id,revision,prepared_by,reviewed_by,evidence_reference)
values(pg_temp.org9(61),'2026-02-01',pg_temp.u(2),1,pg_temp.u(1),pg_temp.u(4),'fictional independent release');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
set local role authenticated;
create temp table personal_result as select public.payroll_self_snapshot(pg_temp.org9(61),'2026-02-01') as x;
select pg_temp.expect((select x->>'userId'=pg_temp.u(2)::text and x->>'employeeContributionCents'='245000' and x->>'netCents'='2654245' and (x->>'sssEmployeeCents')::numeric+(x->>'philhealthEmployeeCents')::numeric+(x->>'pagibigEmployeeCents')::numeric=245000 from personal_result),'employee own deductions reconcile');
select pg_temp.expect((select array(select key from jsonb_object_keys(x) key order by key)=array['employeeContributionCents','grossCents','netCents','organizationId','pagibigEmployeeCents','periodEnd','periodStart','philhealthEmployeeCents','revision','source','sssEmployeeCents','userId','withholdingCents'] from personal_result),'employee exact allowlist excludes employer contributions and costs');
create temp table personal_detail as select public.payroll_self_detail(pg_temp.org9(61),'2026-02-01') as x;
select pg_temp.expect((select x->'summary'=(select x from personal_result) and x->>'frequency'='monthly' and x->>'basicCents'='3000000' and x->>'taxableCents'='2755000' and x->>'paymentConfirmed'='false' from personal_detail),'detailed payslip matches released summary and taxable amount');
select pg_temp.expect((select jsonb_array_length(x->'items')=28 and exists(select 1 from jsonb_array_elements(x->'items') i where i->>'code'='REG' and i->>'seconds'='28800' and i->>'siteReference'='fictional-site') from personal_detail),'payslip includes sealed historical worksite and duration');
select pg_temp.expect((select not exists(select 1 from jsonb_array_elements(x->'items') i where exists(select 1 from jsonb_object_keys(i) k where k not in ('date','code','start','end','seconds','hourlyRate','multiplier','recordedAmount','calculatedAmount','siteReference','method'))) from personal_detail),'nested payslip item allowlist excludes private evidence');
select pg_temp.expect((select x->>'sssRegularCents'='100000' and x->>'sssMpfCents'='50000' and x->>'releasedAt' is not null from personal_detail),'employee SSS split and release time reconcile');
select pg_temp.expect((select exists(select 1 from jsonb_array_elements(x->'items') i where i->>'code'='REG' and (i->>'calculatedAmount')::numeric=0 and i->>'recordedAmount' is null) from personal_detail),'monthly regular work is not double counted as separate salary');
select pg_temp.denied($$select public.payroll_self_detail(pg_temp.org9(62),'2026-02-01')$$,'42501','detail cannot bypass workspace release gate');
-- Scoped lifecycle history, YTD, and idempotent dispute intake.
select pg_temp.expect((public.payroll_self_history(pg_temp.org9(61),2026)->>'periodCount')::int=1 and public.payroll_self_history(pg_temp.org9(61),2026)->>'netCents'='2654245','own released history and YTD reconcile');
select pg_temp.expect(public.payroll_self_history(pg_temp.org9(61),2026)->>'coverageComplete'='false','YTD never claims complete annual coverage');
select pg_temp.denied($$select public.payroll_self_history(pg_temp.org9(62),2026)$$,'42501','history denies unauthorized workspace');
select pg_temp.denied($$select public.payroll_self_history(pg_temp.org9(61),2025)$$,'22023','unsupported history year denied');
select pg_temp.denied($$select public.payroll_self_dispute(pg_temp.org9(61),'2026-02-01',2,0,'fictional payroll dispute')$$,'22023','dispute rejects stale revision');
select pg_temp.denied($$select public.payroll_self_dispute(pg_temp.org9(61),'2026-02-01',1,9999,'fictional payroll dispute')$$,'22023','dispute rejects invalid ordinal');
select pg_temp.expect(public.payroll_self_dispute(pg_temp.org9(61),'2026-02-01',1,0,'fictional payroll dispute')=public.payroll_self_dispute(pg_temp.org9(61),'2026-02-01',1,0,'fictional payroll dispute'),'identical retry returns same dispute receipt');
select pg_temp.denied($$select public.payroll_self_dispute(pg_temp.org9(61),'2026-02-01',1,0,'different fictional reason')$$,'23505','duplicate dispute cannot overwrite');
select pg_temp.expect(jsonb_array_length(public.payroll_self_disputes(pg_temp.org9(61),'2026-02-01'))=1,'employee own dispute list');
select pg_temp.denied($$select public.payroll_dispute_inbox(pg_temp.org9(61),'2026-02-01')$$,'42501','employee cannot access reviewer inbox');
select pg_temp.expect(not has_table_privilege('authenticated','app.ph_employee_payroll_dispute','SELECT') and not has_table_privilege('authenticated','app.ph_employee_payroll_dispute','INSERT'),'dispute raw table inaccessible');
select pg_temp.denied($$select public.payroll_management_snapshot(pg_temp.org9(61),'2026-02-02')$$,'42501','employee organization monetary review denied');
select pg_temp.denied($$select public.accounting_review_snapshot(pg_temp.org9(61),'2026-02-02','organization')$$,'42501','employee organization attendance denied');
select pg_temp.denied($$select public.payroll_self_snapshot(pg_temp.org9(62),'2026-02-01')$$,'42501','other workspace without release gate denied');
reset role;
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select pg_temp.denied($$select public.payroll_self_snapshot(pg_temp.org9(61),'2026-02-01')$$,'P0001','peer cannot select another employee');
select pg_temp.denied($$select public.payroll_self_detail(pg_temp.org9(61),'2026-02-01')$$,'P0001','detail cannot reveal peer payroll');
select pg_temp.expect((public.payroll_self_history(pg_temp.org9(61),2026)->>'periodCount')::int=0,'peer history contains no other employee');
select pg_temp.denied($$select public.payroll_self_disputes(pg_temp.org9(61),'2026-02-01')$$,'P0001','peer cannot read dispute receipts');
select pg_temp.denied($$select public.payroll_self_dispute(pg_temp.org9(61),'2026-02-01',1,0,'fictional payroll dispute')$$,'P0001','peer cannot dispute another employee');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.denied($$select public.payroll_self_snapshot(pg_temp.org9(61),'2026-02-01')$$,'P0001','manager personal endpoint cannot return subordinate payroll');
select pg_temp.expect(not has_table_privilege('authenticated','app.ph_employee_payroll_release','INSERT') and not has_table_privilege('authenticated','app.ph_monetary_snapshot','SELECT') and not has_function_privilege('anon','public.payroll_self_snapshot(uuid,date)','EXECUTE'),'release and raw monetary table private');
-- Reversing a released revision invalidates its personal view. The replacement
-- must be explicitly released again, even for the same employee and period.
select pg_temp.attest(pg_temp.org9(61),'reversal','2026-02-01','{"undispatched":true,"reason":"fictional personal release correction"}');
select app.ph_post_canonical_reversal(pg_temp.org9(61),pg_temp.u(2),'2026-02-01');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
select pg_temp.denied($$select public.payroll_self_snapshot(pg_temp.org9(61),'2026-02-01')$$,'P0001','reversed released revision is not visible');
select pg_temp.attest(pg_temp.org9(61),'replay','2026-02-01',(select a.payload||jsonb_build_object('taxableExtras',1000,'reason','fictional corrected supplement','undispatched',true,'originalAttestation',a.id) from app.ph_payroll_attestation a where a.organization_id=pg_temp.org9(61) and a.kind='period'));
select app.ph_replay_cutoff_2026(pg_temp.org9(61),pg_temp.u(2),'2026-02-01');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
select pg_temp.denied($$select public.payroll_self_snapshot(pg_temp.org9(61),'2026-02-01')$$,'P0001','replacement needs separate release');
select pg_temp.denied($$select public.payroll_self_detail(pg_temp.org9(61),'2026-02-01')$$,'P0001','detail requires release of replacement revision');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
insert into app.ph_employee_payroll_release(organization_id,period_start,user_id,revision,prepared_by,reviewed_by,evidence_reference)
values(pg_temp.org9(61),'2026-02-01',pg_temp.u(2),2,pg_temp.u(1),pg_temp.u(4),'fictional independent replacement release');
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
select pg_temp.expect((public.payroll_self_snapshot(pg_temp.org9(61),'2026-02-01')->>'revision')::int=2 and (public.payroll_self_snapshot(pg_temp.org9(61),'2026-02-01')->>'netCents')='2739245','only newly released effective replacement visible');
select pg_temp.expect(public.payroll_self_history(pg_temp.org9(61),2026)->>'netCents'='2739245' and (public.payroll_self_history(pg_temp.org9(61),2026)->>'periodCount')::int=1,'YTD excludes reversed original and uses effective replacement once');
select pg_temp.expect(jsonb_array_length(public.payroll_self_disputes(pg_temp.org9(61),'2026-02-01'))=0,'replacement does not inherit original item dispute');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.expect(jsonb_array_length(public.payroll_dispute_inbox(pg_temp.org9(61),'2026-02-01'))=1,'authorized payroll reviewer retains original dispute');
-- Original case survives correction without mutating the monetary ledger.
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
set local role authenticated;
select pg_temp.denied($$select public.payroll_dispute_review(pg_temp.org9(61),'2026-02-01')$$,'42501','employee cannot open reviewer dashboard');
select pg_temp.expect(jsonb_array_length(public.payroll_self_dispute_status(pg_temp.org9(61),'2026-02-01'))=1,'employee retains historical dispute receipt');
select pg_temp.denied($$select public.payroll_dispute_propose(pg_temp.org9(61),'2026-02-01',pg_temp.u(2),1,0,'correction_required','fictional correction needed')$$,'42501','employee cannot propose resolution');
reset role;
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
set local role authenticated;
select pg_temp.expect(public.payroll_dispute_review(pg_temp.org9(61),'2026-02-01')->'rows'->0->>'canPropose'='true','payroll maker may propose');
select pg_temp.denied($$select public.payroll_dispute_propose(pg_temp.org9(61),'2026-02-01',pg_temp.u(4),1,0,'correction_required','fictional correction needed')$$,'42501','payroll cannot review own dispute');
select pg_temp.denied($$select public.payroll_dispute_review(pg_temp.org9(62),'2026-02-01')$$,'42501','reviewer cannot bypass workspace review gate');
select public.payroll_dispute_propose(pg_temp.org9(61),'2026-02-01',pg_temp.u(2),1,0,'correction_required','fictional correction needed');
select pg_temp.denied($$select public.payroll_dispute_decide(pg_temp.org9(61),'2026-02-01',pg_temp.u(2),1,0,'approved','fictional independent check')$$,'42501','maker cannot approve own proposal');
reset role;
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
set local role authenticated;
select pg_temp.expect(public.payroll_dispute_review(pg_temp.org9(61),'2026-02-01')->'rows'->0->>'canDecide'='true','independent owner may decide');
select pg_temp.expect(public.payroll_dispute_decide(pg_temp.org9(61),'2026-02-01',pg_temp.u(2),1,0,'approved','fictional independent check')->>'status'='correction_required','independent decision records referral');
select pg_temp.denied($$select public.payroll_dispute_decide(pg_temp.org9(61),'2026-02-01',pg_temp.u(2),1,0,'declined','different fictional check')$$,'23505','decision cannot be overwritten');
select pg_temp.expect(not has_table_privilege('authenticated','app.ph_dispute_decision','INSERT'),'raw resolution write denied');
reset role;
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
select pg_temp.expect(public.payroll_self_dispute_status(pg_temp.org9(61),'2026-02-01')->0->>'status'='correction_required','employee sees approved resolution of original revision');
select pg_temp.expect(public.payroll_self_snapshot(pg_temp.org9(61),'2026-02-01')->>'netCents'='2739245','dispute decision never changes payroll');
rollback;
