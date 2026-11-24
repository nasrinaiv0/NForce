\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(15,'monthly','2026-02-01','daily',700,false,'none',false,'2026-02-10');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.denied($$select app.ph_post_cutoff_2026(pg_temp.org9(15),pg_temp.u(2),'2026-02-01')$$,'P0001','missing leave allocation blocks cutoff');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select app.ph_record_paid_leave_day(pg_temp.org9(15),pg_temp.u(2),'2026-02-09','2026-02-10',480,(select id from public.approval_requests where organization_id=pg_temp.org9(15) and kind='leave'));
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(15),pg_temp.u(2),'2026-02-01')->>'gross')::numeric=14000,'daily-paid monthly cutoff paid leave replaces one workday');
select pg_temp.expect((select gross=14000 and net=11550 from app.ph_effective_monetary where organization_id=pg_temp.org9(15)),'paid leave and agency deductions reconcile');
select pg_temp.expect((select count(*)=1 from app.ph_paid_leave_allocation where organization_id=pg_temp.org9(15)),'one canonical leave allocation');
select pg_temp.denied($$insert into app.ph_paid_leave_allocation(organization_id,user_id,period_start,work_date,request_id,minutes) values(pg_temp.org9(15),pg_temp.u(2),'2026-02-09','2026-02-11',(select id from public.approval_requests where organization_id=pg_temp.org9(15) and kind='leave'),480)$$,'42501','late leave allocation blocked across monthly cutoff');
select pg_temp.seed9(16,'monthly','2026-02-01','monthly',30000,false,'none',false,'2026-02-10');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select app.ph_record_paid_leave_day(pg_temp.org9(16),pg_temp.u(2),'2026-02-09','2026-02-10',480,(select id from public.approval_requests where organization_id=pg_temp.org9(16) and kind='leave'));
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(16),pg_temp.u(2),'2026-02-01')->>'gross')::numeric=30000,'monthly-paid leave not added twice');
\if :{?p15_capture}
\ir p1_5_golden_capture.sql
\endif
rollback;
