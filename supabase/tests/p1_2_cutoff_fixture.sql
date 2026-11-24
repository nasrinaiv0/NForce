create function pg_temp.org9(i int) returns uuid language sql as $$select ('fc900000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid$$;
create function pg_temp.attest(o uuid,k text,d date,p jsonb) returns uuid language plpgsql as $$
declare id uuid;begin
 perform set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
 id:=app.ph_prepare_payroll_evidence(o,pg_temp.u(2),k,d,p,'fictional source reference');
 perform set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
 perform app.ph_approve_payroll_evidence(o,id,'independent fictional review');
 return id;
end $$;
create function pg_temp.seed9(i int,freq text,first_date date,basis text,pay numeric,mwe boolean,benefit text, full_month boolean default false,leave_day date default null, seal_next_day boolean default false)
returns uuid language plpgsql as $$
declare o uuid:=pg_temp.org9(i);e date:=case when full_month then (date_trunc('month',first_date)+interval '1 month - 1 day')::date else app.ph_period_end(first_date,freq) end;w date;d date;t uuid;j jsonb;ls jsonb;nonwork jsonb:='{}';
 keys jsonb:='[]';minw numeric;ord text;from_wage date;through_wage date;ded numeric;alloc date;other_used numeric:=0;leave_id uuid;
begin
 perform set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
 insert into public.organizations(id,name,time_zone) values(o,'Fictional P0.9 '||i,'Asia/Manila');
 insert into public.memberships(organization_id,user_id,status) select o,pg_temp.u(k),'active' from generate_series(1,4)k;
 insert into public.membership_roles(membership_id,role_id)
 select m.id,r.id from public.memberships m join public.roles r on r.organization_id is null and r.key=case when m.user_id=pg_temp.u(1) then 'owner' when m.user_id=pg_temp.u(4) then 'payroll' else 'staff' end where m.organization_id=o;

 if leave_day is not null then
 update public.memberships set reports_to=(select id from public.memberships where organization_id=o and user_id=pg_temp.u(1)) where organization_id=o and user_id=pg_temp.u(2);
 insert into public.leave_types(organization_id,key,name,annual_days) values(o,'vacation','Fictional vacation',5);
 insert into public.leave_transactions(organization_id,user_id,leave_type,kind,days) values(o,pg_temp.u(2),'vacation','accrual',5);
 perform set_config('request.jwt.claim.sub',pg_temp.u(2)::text,true);
 select (public.submit_request(o,'leave',jsonb_build_object('leaveTypeId','vacation','start',leave_day,'end',leave_day,'days',1))).id into leave_id;
 perform set_config('request.jwt.claim.sub',pg_temp.u(1)::text,true);
 perform public.decide_request(leave_id,'approve');
 end if;
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
  for d in select w+k from generate_series(0,6)k where w+k between first_date and (e+case when seal_next_day then 1 else 0 end) loop
   insert into app.accounting_roster_day values(o,w,pg_temp.u(2),d,480,0,'fictional policy');
   perform app.ph_record_workday(o,w,pg_temp.u(2),d,(d+time '08:00') at time zone 'Asia/Manila',
   jsonb_build_object(d::text,case when extract(isodow from d)<=5 then 'ordinary' else 'rest' end,(d+1)::text,'ordinary'),'fictional workday');
   if d>e then continue;end if;
   if d=leave_day then
    nonwork:=nonwork||jsonb_build_object(d::text,jsonb_build_object('kind','paid_leave','reference','fictional approved paid leave','minutes',480,'requestId',leave_id));
   elsif extract(isodow from d)<=5 then
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
 if basis='monthly' then
 perform pg_temp.attest(o,'divisor',first_date,jsonb_build_object('recordedAt','2026-01-01T00:00:00Z','annualPaidDays',365));
 perform pg_temp.attest(o,'salary_month',first_date,jsonb_build_object('method','full-calendar-month-no-unpaid-days','effectiveOn',first_date,'recordedAt','2026-01-01T00:00:00Z'));
 end if;
 perform pg_temp.attest(o,'cutoff_opening','2026-01-01',jsonb_build_object('frequency',freq,'firstPeriod',first_date,'currentStart',first_date,'certificates','[]'::jsonb,'previousPeriods',0,'completeCurrentYtd',true,
 'benefitOpening',jsonb_build_object('through',first_date-1,'buckets','{}'::jsonb,'other',other_used,'medicalMode','monthly')));
 alloc:=case when freq='monthly' then e else (date_trunc('month',e)+interval '1 month - 1 day')::date end;
 ded:=case when e=alloc then 2450 else 0 end;
 perform pg_temp.attest(o,'contribution',date_trunc('month',e)::date,jsonb_build_object('allocationDate',alloc,'sss',30000,'philhealth',30000,'pagibig',30000));
 if full_month then
 perform pg_temp.attest(o,'period',first_date,jsonb_build_object('end',first_date+14,'frequency',freq,'coverage','ordinary-covered-complete','nonwork',(select coalesce(jsonb_object_agg(key,value),'{}') from jsonb_each(nonwork) where key::date<=first_date+14),'benefitKeys','[]'::jsonb,'cumulative',false,'taxDeductible',0,'taxableExtras',15000,'hazardPay',0));
 perform pg_temp.attest(o,'period',first_date+15,jsonb_build_object('end',e,'frequency',freq,'coverage','ordinary-covered-complete','nonwork',(select coalesce(jsonb_object_agg(key,value),'{}') from jsonb_each(nonwork) where key::date>first_date+14),'benefitKeys',jsonb_build_array('fixture-final-13th'),'cumulative',false,'taxDeductible',2450,'taxableExtras',0,'hazardPay',0));
 return o;
 end if;
 perform pg_temp.attest(o,'period',first_date,jsonb_build_object('end',e,'frequency',freq,'coverage','ordinary-covered-complete','nonwork',nonwork,'benefitKeys',keys,
 'cumulative',false,'taxDeductible',ded,'taxableExtras',case when benefit='rice' then 1000 else 0 end,'hazardPay',0));
 return o;
end $$;

