
\set ON_ERROR_STOP on
begin;
\ir p0_9_monthly_fixture.sql
select app.accounting_lock(pg_temp.org(),'2026-01-12');
insert into public.leave_types(organization_id,key,name,annual_days) values(pg_temp.org(),'vacation','Fictional vacation',5);
insert into public.leave_transactions(organization_id,user_id,leave_type,kind,days) values(pg_temp.org(),pg_temp.u(2),'vacation','accrual',5);
select set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
create temp table leave_req as select (public.submit_request(pg_temp.org(),'leave','{"leaveTypeId":"vacation","start":"2026-01-14","end":"2026-01-14","days":1}')).id;
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select public.decide_request((select id from leave_req),'approve');
select app.ph_open_benefit_year(pg_temp.org(),pg_temp.u(2),'2026-01-05','{}',0,'monthly','fictional reviewed opening');
create temp table ev(kind text,id uuid);
insert into ev select 'opening',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'opening','2026-01-01','{"method":"weekly","previousPeriods":0,"certificates":[],"currentStart":"2026-01-01","firstPeriod":"2026-01-12"}','fictional reviewed opening');
insert into ev select 'month',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'month','2026-01-01','{"sss":5000,"philhealth":10000,"pagibig":5000,"allocationPeriod":"2026-01-12"}','fictional classified contribution bases');
insert into ev select 'divisor',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'divisor','2026-01-01','{"recordedAt":"2026-01-01T00:00:00Z","annualPaidDays":365}','fictional reviewed divisor');
insert into ev select 'salary_month',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'salary_month','2026-01-01','{"method":"full-calendar-month-no-unpaid-days","effectiveOn":"2026-01-01","recordedAt":"2026-01-01T00:00:00Z"}','fictional closed salary month');
insert into ev select 'week',app.ph_prepare_payroll_evidence(pg_temp.org(),pg_temp.u(2),'week','2026-01-12',jsonb_build_object('coverage','ordinary-rank-and-file-taxable-complete','nonwork',jsonb_build_array(jsonb_build_object('date','2026-01-14','minutes',480,'kind','paid_leave','reference','fictional approved leave','requestId',(select id from leave_req))),'supplemental','[]'::jsonb),'fictional complete salary week');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_approve_payroll_evidence(pg_temp.org(),id,'fictional independent check') from ev order by kind;
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.denied($$select app.ph_post_monetary_week_2026(pg_temp.org(),'2026-01-12',pg_temp.u(2))$$,'P0001','missing paid leave allocation blocks salary posting');
select app.ph_record_paid_leave_day(pg_temp.org(),pg_temp.u(2),'2026-01-12','2026-01-14',480,(select id from leave_req));
select pg_temp.denied($$select app.ph_record_paid_leave_day(pg_temp.org(),pg_temp.u(2),'2026-01-12','2026-01-14',480,(select id from leave_req))$$,'22023','leave cannot be allocated twice');
select app.ph_post_monetary_week_2026(pg_temp.org(),'2026-01-12',pg_temp.u(2));
select pg_temp.expect((select gross=7285.83 and taxable=6685.83 and withholding=281.67 and net=6404.16 from app.ph_monetary_snapshot where organization_id=pg_temp.org()),'guaranteed salary plus incremental premiums without duplicate paid leave');
select pg_temp.expect((select sum((x->>'amount')::numeric)=6774.19 from app.ph_monetary_snapshot s cross join lateral jsonb_array_elements(s.evidence->'earnings')x where x->>'code'='guaranteed_salary'),'seven-day base guaranteed independently of punches');
select pg_temp.expect((select sum((x->>'credit')::numeric)=1460 from app.ph_payroll_journal j cross join lateral jsonb_array_elements(j.lines)x where x->>'account' in ('sss_payable','philhealth_payable','pagibig_payable')),'agency payable account credits match report');
rollback;
