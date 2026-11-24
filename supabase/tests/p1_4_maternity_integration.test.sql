\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
\ir p1_2_cutoff_fixture.sql
\ir p1_4_maternity_integration_fixture.sql
select pg_temp.expect((app.ph_post_maternity_contributions(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')->>'journalTotal')::numeric=22175,'balanced maternity contribution accrual');
select pg_temp.expect((app.ph_post_maternity_contributions(pg_temp.org9(27),pg_temp.u(2),'2026-06-14')->>'journalTotal')::numeric=22175,'maternity contribution retry idempotent');
select pg_temp.expect((select count(*)=1 from app.ph_statutory_journal where organization_id=pg_temp.org9(27) and category='maternity_contribution'),'one canonical maternity contribution journal');
select pg_temp.attest(pg_temp.org9(27),'wage','2026-03-13','{"region":"XI","locality":"Davao City","sector":"non-agriculture","coverage":"ordinary private sector","site":"fictional-site","order":"RB XI-23","source":"https://nwpc.dole.gov.ph/region-xi/","documentSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","through":"2026-07-31","dailyMinimum":510}');
select pg_temp.attest(pg_temp.org9(27),'salary_month',g::date,'{"method":"full-calendar-month-no-unpaid-days","effectiveOn":"2026-02-01","recordedAt":"2026-01-01T00:00:00Z"}') from generate_series(date '2026-03-01',date '2026-06-01',interval '1 month')g;
select pg_temp.attest(pg_temp.org9(27),'period',g::date,jsonb_build_object('end',(g+interval '1 month - 1 day')::date,'frequency','monthly','coverage','ordinary-covered-complete',
 'nonwork',(select jsonb_object_agg(d::date::text,jsonb_build_object('kind',case when d::date between date '2026-03-02' and date '2026-06-14' then 'maternity_covered' else 'monthly_covered' end,'reference','fictional reviewed paid coverage')) from generate_series(g,g+interval '1 month - 1 day',interval '1 day')d where d::date<=date '2026-06-14' or extract(isodow from d)>5),
 'benefitKeys','[]'::jsonb,'cumulative',false,'taxDeductible',case when g::date='2026-03-01' then 150 when g::date='2026-06-01' then 1225 else 0 end,'taxableExtras',0,'hazardPay',0,
 'maternityAllocation',(select attestation_id from app.ph_statutory_journal where organization_id=pg_temp.org9(27) and category='maternity_contribution'))) from generate_series(date '2026-03-01',date '2026-06-01',interval '1 month')g;
select pg_temp.denied($$select app.ph_post_cutoff_2026(pg_temp.org9(27),pg_temp.u(2),'2026-06-01')$$,'P0001','cannot skip maternity payroll months');
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(27),pg_temp.u(2),'2026-03-01')->>'gross')::numeric=967.74,'March ordinary residual salary');
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(27),pg_temp.u(2),'2026-04-01')->>'gross')::numeric=0,'April already paid maternity no duplicate salary');
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(27),pg_temp.u(2),'2026-05-01')->>'gross')::numeric=0,'May already paid maternity no duplicate salary');
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(27),pg_temp.u(2),'2026-06-01')->>'gross')::numeric=16000,'June ordinary payroll resumes after leave');
select pg_temp.expect((select sum(employee_contributions)=1375 and sum(employer_contributions)=2170 from app.ph_effective_monetary where organization_id=pg_temp.org9(27) and period_start>='2026-03-01'),'ordinary residual plus maternity shares equals four agency months');
select pg_temp.attest(pg_temp.org9(27),'statutory_quote','2026-07-01','{"category":"thirteenth","basic":46967.74,"maternity":26575,"integratedBasic":0,"paid":0,"eligible":true}');
select pg_temp.attest(pg_temp.org9(27),'entitlement','2026-07-01','{"quoteDate":"2026-07-01","category":"thirteenth","payDate":"2026-07-01"}');
select pg_temp.expect((app.ph_settle_reviewed_thirteenth(pg_temp.org9(27),pg_temp.u(2),'2026-07-01')->>'amount')::numeric=6128.56,'canonical maternity inclusive thirteenth accrual');
select pg_temp.denied($$select app.ph_settle_reviewed_thirteenth(pg_temp.org9(27),pg_temp.u(2),'2026-07-01')$$,'P0001','duplicate maternity inclusive thirteenth denied');
select pg_temp.expect(not has_function_privilege('authenticated','app.ph_post_maternity_contributions(uuid,uuid,date)','EXECUTE'),'maternity contribution posting private');

select pg_temp.attest(pg_temp.org9(27),'salary_month','2026-07-01','{"method":"full-calendar-month-no-unpaid-days","effectiveOn":"2026-02-01","recordedAt":"2026-01-01T00:00:00Z"}');
select pg_temp.attest(pg_temp.org9(27),'contribution','2026-07-01','{"allocationDate":"2026-07-31","sss":30000,"philhealth":30000,"pagibig":30000}');
select pg_temp.attest(pg_temp.org9(27),'period','2026-07-01',jsonb_build_object('end','2026-07-31','frequency','monthly','coverage','ordinary-covered-complete',
 'nonwork',(select jsonb_object_agg(d::date::text,jsonb_build_object('kind','monthly_covered','reference','fictional reviewed weekend')) from generate_series(date '2026-07-01',date '2026-07-31',interval '1 day')d where extract(isodow from d)>5),
 'benefitKeys',(select jsonb_agg(event_key order by event_key) from app.ph_benefit_event where organization_id=pg_temp.org9(27) and user_id=pg_temp.u(2)),
 'cumulative',false,'taxDeductible',2450,'taxableExtras',0,'hazardPay',0));
select pg_temp.expect((app.ph_post_cutoff_2026(pg_temp.org9(27),pg_temp.u(2),'2026-07-01')->>'gross')::numeric=36128.56,'full ordinary month consumes maternity inclusive thirteenth once');
select pg_temp.expect((select basic is not null from (select evidence->>'basic' basic from app.ph_effective_monetary where organization_id=pg_temp.org9(27) and period_start='2026-07-01')s),'ordinary monthly calculator resumed');
select pg_temp.expect((select net=32671.01 and exempt=6128.56 and taxable=27550 from app.ph_effective_monetary where organization_id=pg_temp.org9(27) and period_start='2026-07-01'),'ordinary resumed gross to net exact');
select pg_temp.expect((select count(*)=1 from app.ph_benefit_event where organization_id=pg_temp.org9(27)),'single canonical thirteenth benefit event');
rollback;
