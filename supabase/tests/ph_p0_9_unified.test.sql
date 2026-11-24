\set ON_ERROR_STOP on
begin;
\ir p0_3_fixture.sql
-- Fictional exact-locked source fixtures, independent of monetary arithmetic.
-- The inherited PR12 suite exercises actual attendance replay and approval.
create function pg_temp.org9(i int) returns uuid language sql as $$select ('fc900000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid$$;
create function pg_temp.attest(o uuid,k text,d date,p jsonb) returns uuid language plpgsql as $$
declare id uuid;begin
 perform set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
 id:=app.ph_prepare_payroll_evidence(o,pg_temp.u(2),k,d,p,'fictional source reference');
 perform set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
 perform app.ph_approve_payroll_evidence(o,id,'independent fictional review');
 return id;
end $$;
create function pg_temp.seed9(i int,freq text,first_date date,basis text,pay numeric,mwe boolean,benefit text)
returns uuid language plpgsql as $$
declare o uuid:=pg_temp.org9(i);e date:=app.ph_period_end(first_date,freq);w date;d date;t uuid;j jsonb;ls jsonb;nonwork jsonb:='{}';
 keys jsonb:='[]';minw numeric;ord text;from_wage date;through_wage date;ded numeric;alloc date;other_used numeric:=0;
begin
 perform set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
 insert into public.organizations(id,name,time_zone) values(o,'Fictional P0.9 '||i,'Asia/Manila');
 insert into public.memberships(organization_id,user_id,status) select o,pg_temp.u(k),'active' from generate_series(1,4)k;
 insert into public.membership_roles(membership_id,role_id)
 select m.id,r.id from public.memberships m join public.roles r on r.organization_id is null and r.key=case when m.user_id=pg_temp.u(1) then 'owner' when m.user_id=pg_temp.u(4) then 'payroll' else 'staff' end where m.organization_id=o;
 minw:=case when first_date>=date '2026-09-01' then 540 else 510 end;
 ord:=case when first_date>=date '2026-09-01' then 'RB XI-24' else 'RB XI-23' end;
 from_wage:=case when first_date>=date '2026-09-01' then date '2026-09-01' else date '2026-01-01' end;
 through_wage:=case when first_date>=date '2026-09-01' then date '2026-11-24' else date '2026-03-12' end;
 insert into app.ph_employment_history values(o,pg_temp.u(2),first_date,'2026-01-01Z','employed',basis,pay,'fictional-site',ord,'fixture historical revision',pg_temp.u(1));
 if benefit='rice' then other_used:=90000;end if;
 perform app.ph_open_benefit_year(o,pg_temp.u(2),first_date-1,'{}',other_used,'monthly','fictional opening balances');
 if benefit='rice' then
 perform app.ph_post_benefit(o,pg_temp.u(2),'p09-benefit-rice',e,'rice',3000,null,null,'fixture benefit');keys:='["p09-benefit-rice"]';
 elsif benefit='13th' then
 perform app.ph_post_benefit(o,pg_temp.u(2),'p09-benefit-13th',e,'13th_month',2500,null,null,'fixture thirteenth');keys:='["p09-benefit-13th"]';
 end if;
 -- Build sealed weekly evidence spanning the selected cutoff, with weekday
 -- work and explicitly attested weekend nonwork. No actual employee data.
 for w in select (first_date-(extract(isodow from first_date)::int-1))+k*7
 from generate_series(0,(e-(first_date-(extract(isodow from first_date)::int-1)))/7)k loop
  insert into app.accounting_period_manifest values(o,w,'Asia/Manila','fictional sealed weekly roster',pg_temp.u(1),false);
  ls:='[]';
  for d in select w+k from generate_series(0,6)k where w+k between first_date and e loop
   insert into app.accounting_roster_day values(o,w,pg_temp.u(2),d,480,0,'fictional policy');
   perform app.ph_record_workday(o,w,pg_temp.u(2),d,(d+time '08:00') at time zone 'Asia/Manila',
   jsonb_build_object(d::text,case when extract(isodow from d)<=5 then 'ordinary' else 'rest' end,(d+1)::text,'ordinary'),'fictional workday');
   if extract(isodow from d)<=5 then
    ls:=ls||jsonb_build_array(jsonb_build_object('workday',d,'date',d,'seconds',28800,'multiplier',1,'code','REG'));
   else
    nonwork:=nonwork||jsonb_build_object(d::text,jsonb_build_object('kind',case when basis='monthly' then 'monthly_covered' else 'unpaid_nonwork' end,'reference','reviewed fictional weekend'));
   end if;
  end loop;
  update app.accounting_period_manifest set sealed=true where organization_id=o and period_start=w;
  insert into public.timesheets(organization_id,user_id,period_start,status) values(o,pg_temp.u(2),w,'locked') returning id into t;
  j:=jsonb_build_object('classificationVersion',4,'exactOvertimeReviewSeconds',0,'payLines',ls,'workedSeconds',jsonb_array_length(ls)*28800,'overtimeSeconds',0);
  insert into app.accounting_submission values(o,w,pg_temp.u(2),j,t);
  insert into app.accounting_locked_snapshot values(o,w,pg_temp.u(2),j);
  insert into public.payroll_periods(organization_id,period_start,locked_by) values(o,w,pg_temp.u(1));
 end loop;
 perform pg_temp.attest(o,'wage',from_wage,jsonb_build_object('region','XI','locality','Davao City','sector','non-agriculture','coverage','ordinary private sector','site','fictional-site','order',ord,
 'source','https://nwpc.dole.gov.ph/region-xi/','documentSha256',repeat('a',64),'through',through_wage,'dailyMinimum',minw));
 perform pg_temp.attest(o,'opening','2026-01-01',jsonb_build_object('frequency',freq,'firstPeriod',first_date,'currentStart',first_date,'certificates','[]'::jsonb,'previousPeriods',0,'completeCurrentYtd',true,
 'benefitOpening',jsonb_build_object('through',first_date-1,'buckets','{}'::jsonb,'other',other_used,'medicalMode','monthly')));
 alloc:=case when freq='monthly' then e else (date_trunc('month',e)+interval '1 month - 1 day')::date end;
 ded:=case when freq='monthly' then 2450 else 0 end;
 perform pg_temp.attest(o,'contribution',date_trunc('month',e)::date,jsonb_build_object('allocationDate',alloc,'sss',30000,'philhealth',30000,'pagibig',30000));
 perform pg_temp.attest(o,'period',first_date,jsonb_build_object('end',e,'frequency',freq,'coverage','ordinary-covered-complete','nonwork',nonwork,'benefitKeys',keys,
 'cumulative',false,'taxDeductible',ded,'taxableExtras',case when benefit='rice' then 1000 else 0 end,'hazardPay',0));
 return o;
end $$;
select pg_temp.seed9(1,'daily','2026-09-15','daily',540,true,'rice');
select pg_temp.seed9(2,'weekly','2026-01-12','daily',600,false,'none');
select pg_temp.seed9(3,'semi-monthly','2026-02-01','monthly',30000,false,'none');
select pg_temp.seed9(4,'monthly','2026-02-01','monthly',30000,false,'13th');
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select pg_temp.denied($$select app.ph_post_period_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')$$,'42501','period maker cannot post');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
do $$ declare j jsonb;begin
j:=app.ph_post_period_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15');
perform pg_temp.expect((j->>'gross')::numeric=4540 and (j->>'exempt')::numeric=3040 and (j->>'taxable')::numeric=1500 and (j->>'withholding')::numeric=142.45 and (j->>'net')::numeric=4397.55,'daily MWE and ledger benefit exact');
j:=app.ph_post_period_2026(pg_temp.org9(2),pg_temp.u(2),'2026-01-12');
perform pg_temp.expect((j->>'gross')::numeric=3000 and (j->>'net')::numeric=3000,'weekly daily-paid actual work');
j:=app.ph_post_period_2026(pg_temp.org9(3),pg_temp.u(2),'2026-02-01');
perform pg_temp.expect((j->>'gross')::numeric=15000 and (j->>'withholding')::numeric=687.45 and (j->>'net')::numeric=14312.55,'semi-monthly full salary half');
j:=app.ph_post_period_2026(pg_temp.org9(4),pg_temp.u(2),'2026-02-01');
perform pg_temp.expect((j->>'gross')::numeric=32500 and (j->>'exempt')::numeric=2500 and (j->>'employeeContrib')::numeric=2450 and (j->>'employerContrib')::numeric=3980 and (j->>'net')::numeric=29042.45,'monthly gross net and 13th benefit ledger');
end $$;
select pg_temp.expect((select count(*)=4 from app.ph_money_snapshot where extract(year from pay_month)=2026),'four frequencies one physical ledger');
select pg_temp.expect(not exists(select 1 from app.ph_money_journal group by organization_id,user_id,pay_month,revision having sum(debit-credit)<>0),'all four journals balance');
select pg_temp.expect((app.ph_post_period_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')->>'net')::numeric=4397.55,'period retry idempotent');
select pg_temp.denied($$select app.ph_post_benefit(pg_temp.org9(1),pg_temp.u(2),'late-p09-benefit','2026-09-15','rice',1,null,null,'fixture late event')$$,'42501','late benefit cannot change posted period');
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select pg_temp.denied($$select app.ph_post_period_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')$$,'42501','staff monetary access denied');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.denied($$select app.ph_post_period_2026('fc900000-0000-0000-0000-000000000099',pg_temp.u(2),'2026-09-15')$$,'42501','cross-tenant monetary access denied');
-- Reversal and same-engine replacement, original revision remains immutable.
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
select app.ph_propose_reversal(pg_temp.org9(1),pg_temp.u(2),'2026-09-15','fictional supplemental correction','reviewed undispatched accrual');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_approve_reversal(pg_temp.org9(1),pg_temp.u(2),'2026-09-15','independent reversal review');
select pg_temp.denied($$select app.ph_post_period_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')$$,'P0001','normal posting blocked pending replay');
select pg_temp.attest(pg_temp.org9(1),'replay','2026-09-15',
 (select a.payload||jsonb_build_object('taxableExtras',1200,'reason','correct supplemental compensation','undispatched',true,'originalAttestation',a.id)
 from app.ph_payroll_attestation a where a.organization_id=pg_temp.org9(1) and a.kind='period'));
select pg_temp.expect((app.ph_replay_period_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')->>'net')::numeric=4557.55,'same engine recomputes revised supplement');
select pg_temp.expect((select count(*)=2 from app.ph_money_snapshot where organization_id=pg_temp.org9(1)),'both immutable revisions retained');
select pg_temp.expect((select count(*)=1 and max(revision)=2 from app.ph_money_active where organization_id=pg_temp.org9(1)),'active payroll selects replacement only');
select pg_temp.expect((app.ph_replay_period_2026(pg_temp.org9(1),pg_temp.u(2),'2026-09-15')->>'net')::numeric=4557.55,'replay retry idempotent');
select pg_temp.expect(not exists(select 1 from app.ph_money_journal group by organization_id,user_id,pay_month,revision having sum(debit-credit)<>0),'all original and replacement journals balance');
select pg_temp.expect((select sum(debit-credit)=0 from app.ph_money_reversal_journal where organization_id=pg_temp.org9(1)),'inverse journal balances');
-- Ordinary resignation, final February accrual undispatched; 13th already in ledger.
select set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
insert into app.ph_employment_history values(pg_temp.org9(4),pg_temp.u(2),'2026-03-01','2026-03-01Z','separated',null,null,null,null,'fixture resignation',pg_temp.u(1));
select pg_temp.attest(pg_temp.org9(4),'annual','2026-02-28','{"reason":"termination","available":29042.45,"completeFinalCompensation":true,"undispatched":true,"completeExitEntitlements":true,"exitKind":"ordinary_resignation_no_severance","rankAndFileEligible":true,"maternityDifferential":0,"integratedBasic":0}');
select pg_temp.expect((app.ph_thirteenth_reconcile_2026(pg_temp.org9(4),pg_temp.u(2),'2026-02-28')->>'remaining')::numeric=0,'13th reconciles with paid benefit ledger');
select pg_temp.expect((app.ph_record_annual_settlement_2026(pg_temp.org9(4),pg_temp.u(2),'2026-02-01')->>'refund')::numeric=1007.55,'final tax refund from effective YTD');
select pg_temp.expect((select sum(debit)=1007.55 and sum(credit)=1007.55 from app.ph_annual_journal where organization_id=pg_temp.org9(4)),'balanced final tax refund journal');
select pg_temp.denied($$select app.ph_propose_reversal(pg_temp.org9(4),pg_temp.u(2),'2026-02-01','fictional correction','reviewed source reference')$$,'42501','settled year reversal blocked');
do $$ declare r text;begin
foreach r in array array['anon','authenticated','service_role'] loop
perform pg_temp.expect(not has_table_privilege(r,'app.ph_money_active','SELECT'),'active money view private');
perform pg_temp.expect(not has_function_privilege(r,'app.ph_post_period_2026(uuid,uuid,date)','EXECUTE'),'period posting private');
perform pg_temp.expect(not has_function_privilege(r,'app.ph_replay_period_2026(uuid,uuid,date)','EXECUTE'),'replay private');
perform pg_temp.expect(not has_function_privilege(r,'app.ph_record_annual_settlement_2026(uuid,uuid,date)','EXECUTE'),'final settlement private');
end loop;end $$;
-- Reuse approved statutory calculations, not a second engine.
select pg_temp.attest(pg_temp.org9(4),'statutory_quote','2026-02-28','{"category":"thirteenth","eligible":true,"basic":30000,"maternity":0,"integratedBasic":0,"paid":2500}');
select pg_temp.expect((app.ph_reviewed_statutory_quote(pg_temp.org9(4),pg_temp.u(2),'2026-02-28')->'result'->>'remaining')::numeric=0,'reviewed statutory quote uses canonical benefit calculator');
do $$ declare q jsonb;begin
 q:=app.ph_month_liability_review(pg_temp.org9(4),'2026-02-01');
 perform pg_temp.expect((q->>'gross')::numeric=32500 and (q->>'net')::numeric=29042.45 and (q->>'employerCost')::numeric=36480,'monthly liability review reconciles canonical gross net cost');
 perform pg_temp.expect((q->'accountNetCredits'->>'sss_regular_payable')::numeric=3000 and (q->'accountNetCredits'->>'sss_mpf_payable')::numeric=1500 and (q->'accountNetCredits'->>'sss_ec_payable')::numeric=30,'liability review preserves SSS components');
 perform pg_temp.expect((q->'annualAdjustments'->'bir_withholding_payable'->>'debit')::numeric=1007.55 and q->>'remittanceAuthorized'='false' and q->>'coverageComplete'='false','annual refund separate and no remittance authorization');
 q:=app.ph_month_liability_review(pg_temp.org9(1),'2026-09-01');
 perform pg_temp.expect((q->>'gross')::numeric=4740 and (q->>'net')::numeric=4557.55 and (q->>'periodCount')::int=1 and (q->'sources'->0->>'revision')::int=2,'monthly review excludes reversed original');
end $$;
select set_config('request.jwt.claim.sub',pg_temp.u(3)::text,true);
select pg_temp.denied($$select app.ph_month_liability_review(pg_temp.org9(4),'2026-02-01')$$,'42501','staff cannot review money');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select pg_temp.denied($$select app.ph_month_liability_review('fc900000-0000-0000-0000-000000000099','2026-02-01')$$,'42501','cross tenant liability review denied');
select pg_temp.denied($$select app.ph_month_liability_review(pg_temp.org9(4),'2026-11-01')$$,'22023','open month blocked');
do $$ declare r text;begin
foreach r in array array['anon','authenticated','service_role'] loop
perform pg_temp.expect(not has_function_privilege(r,'app.ph_month_liability_review(uuid,date)','EXECUTE'),'private liability review');
perform pg_temp.expect(not has_function_privilege(r,'app.ph_reviewed_statutory_quote(uuid,uuid,date)','EXECUTE'),'private statutory quote');
end loop;end $$;
rollback;
