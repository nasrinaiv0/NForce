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
 perform pg_temp.attest(o,'cutoff_opening','2026-01-01',jsonb_build_object('frequency',freq,'firstPeriod',first_date,'currentStart',first_date,'certificates','[]'::jsonb,'previousPeriods',0,'completeCurrentYtd',true,
 'benefitOpening',jsonb_build_object('through',first_date-1,'buckets','{}'::jsonb,'other',other_used,'medicalMode','monthly')));
 alloc:=case when freq='monthly' then e else (date_trunc('month',e)+interval '1 month - 1 day')::date end;
 ded:=case when e=alloc then 2450 else 0 end;
 perform pg_temp.attest(o,'contribution',date_trunc('month',e)::date,jsonb_build_object('allocationDate',alloc,'sss',30000,'philhealth',30000,'pagibig',30000));
 perform pg_temp.attest(o,'period',first_date,jsonb_build_object('end',e,'frequency',freq,'coverage','ordinary-covered-complete','nonwork',nonwork,'benefitKeys',keys,
 'cumulative',false,'taxDeductible',ded,'taxableExtras',case when benefit='rice' then 1000 else 0 end,'hazardPay',0));
 return o;
end $$;

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
rollback;
