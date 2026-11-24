-- P1.5: one journal projection for every supported 2026 payroll frequency.
-- Existing weekly/cutoff evidence adapters stay distinct; no second physical ledger.
create function app.ph_canonical_payroll_lines(p_gross numeric,p_ee numeric,p_er numeric,p_tax numeric,p_net numeric,p_contrib jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare k text;v jsonb; x numeric; y numeric; z numeric; ee numeric:=0;er numeric:=0; sss numeric:=0;ph numeric:=0;pi numeric:=0;
begin
 if not app.ph_stat_money(p_gross) or not app.ph_stat_money(p_ee) or not app.ph_stat_money(p_er)
 or not app.ph_stat_money(p_tax) or not app.ph_stat_money(p_net) or p_net<>p_gross-p_ee-p_tax
 or jsonb_typeof(p_contrib) is distinct from 'object'
 or exists(select 1 from jsonb_object_keys(p_contrib) k2 where k2 not in ('sss','philhealth','pagibig'))
 then raise exception 'invalid canonical payroll totals' using errcode='22023';end if;
 foreach k in array array['sss','philhealth','pagibig'] loop
 v:=p_contrib->k;
 if v is null or v='null'::jsonb then continue;end if;
 x:=(v->>'employee')::numeric;y:=(v->>'employer')::numeric;z:=(v->>'total')::numeric;
 if not app.ph_stat_money(x) or not app.ph_stat_money(y) or not app.ph_stat_money(z) or z<>x+y
 then raise exception 'invalid agency components' using errcode='22023';end if;
 ee:=ee+x;er:=er+y;
 case k when 'sss' then sss:=z;when 'philhealth' then ph:=z;else pi:=z;end case;
 end loop;
 if ee<>p_ee or er<>p_er then raise exception 'agency totals do not reconcile' using errcode='22023';end if;
 return jsonb_build_array(jsonb_build_object('account','wage_expense','debit',p_gross,'credit',0),
 jsonb_build_object('account','employer_contribution_expense','debit',p_er,'credit',0),
 jsonb_build_object('account','sss_payable','debit',0,'credit',sss),
 jsonb_build_object('account','philhealth_payable','debit',0,'credit',ph),
 jsonb_build_object('account','pagibig_payable','debit',0,'credit',pi),
 jsonb_build_object('account','withholding_payable','debit',0,'credit',p_tax),
 jsonb_build_object('account','net_payable','debit',0,'credit',p_net));
end $$;
revoke all on function app.ph_canonical_payroll_lines(numeric,numeric,numeric,numeric,numeric,jsonb) from public,anon,authenticated,service_role;
create or replace function app.ph_post_week_version(p_org uuid,p_period date,p_user uuid,p_replay boolean)
returns jsonb language plpgsql set search_path='' as $$
declare original app.ph_monetary_snapshot; existing app.ph_monetary_snapshot; version_no int; s app.accounting_locked_snapshot; o app.ph_monetary_opening; m app.ph_monthly_basis_evidence;
 h app.ph_employment_history; dv app.ph_salary_divisor_evidence; l jsonb;
 line_amount numeric; raw_gross numeric:=0; gross numeric; hourly numeric;
 ee numeric:=0; er numeric:=0; tax numeric; net numeric; taxable numeric;
 prev_taxable numeric; prev_tax numeric; n int; last_period date; pd date:=p_period+6; mon date;
 a app.ph_payroll_attestation; opening app.ph_payroll_attestation; prior jsonb; b app.ph_benefit_event; exempt numeric:=0; d date; minutes numeric; seen date[]:='{}'; ev_day app.ph_workday_evidence;
 salary_mode boolean:=false; salary_days int; known_at timestamptz; base_amount numeric; factor numeric; allocation app.ph_paid_leave_allocation; used numeric; req numeric;
 contrib jsonb:='{}'; j jsonb; agency text; basis numeric; v jsonb; lines jsonb:='[]'; journal jsonb; total numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_period is null or extract(isodow from p_period)<>1 or extract(year from pd)<>2026 or extract(year from p_period)<>2026 or pd>date '2026-11-24' then raise exception 'unsupported monetary period' using errcode='22023'; end if;

 if p_replay is null then raise exception 'posting mode required' using errcode='22023';end if;
 version_no:=case when p_replay then 2 else 1 end;
 if p_replay then
 a:=app.ph_approved_evidence(p_org,p_user,'weekly_replay',p_period);
 if a.maker=auth.uid() then raise exception 'replay maker denied' using errcode='42501';end if;
 select * into original from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_period and revision=1;
 if not found or original.frequency<>'weekly' or a.payload->>'originalAttestation' is distinct from original.evidence->>'attestation'
 or not exists(select 1 from app.ph_canonical_reversal where organization_id=p_org and user_id=p_user and period_start=p_period)
 or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start>p_period)
 or exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026)
 or exists(select 1 from app.ph_month_report where organization_id=p_org and month_start=date_trunc('month',pd)::date)
 then raise exception 'latest unreported reversed week required' using errcode='P0001';end if;
 if (a.payload-array['reason','undispatched','originalAttestation','supplemental']) is distinct from ((app.ph_approved_evidence(p_org,p_user,'week',p_period)).payload-'supplemental') then raise exception 'only supplemental correction supported' using errcode='P0001';end if;
 select * into existing from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_period and revision=2;
 if found then
 if existing.evidence->>'attestation' is distinct from a.id::text then raise exception 'replacement conflict' using errcode='P0001';end if;
 return jsonb_build_object('gross',existing.gross,'net',existing.net,'revision',2);end if;
 else
 if app.ph_unresolved_reversal(p_org,p_user) or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and period_start=p_period and user_id=p_user) then raise exception 'monetary snapshot already posted or unresolved reversal' using errcode='P0001';end if;
 end if;
 select * into s from app.accounting_locked_snapshot where organization_id=p_org and period_start=p_period and user_id=p_user;
 if not found or s.reconciliation->>'classificationVersion' is distinct from '4' or (s.reconciliation->>'exactOvertimeReviewSeconds')::numeric<>0 then raise exception 'locked exact reconciled PH attendance required' using errcode='P0001'; end if;
 if exists(select 1 from app.accounting_adjustment_proposal where organization_id=p_org and period_start=p_period and user_id=p_user) then raise exception 'adjusted payroll requires settlement review' using errcode='P0001'; end if;
 select * into o from app.ph_monetary_opening where organization_id=p_org and user_id=p_user and tax_year=2026;
 if not found then raise exception 'reviewed zero opening and coverage required' using errcode='P0001'; end if;
 opening:=app.ph_approved_evidence(p_org,p_user,'opening','2026-01-01');
 a:=app.ph_approved_evidence(p_org,p_user,case when p_replay then 'weekly_replay' else 'week' end,p_period);
 prior:=app.ph_prior_employer_2026(p_org,p_user);
 if exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'annual settlement already recorded' using errcode='P0001'; end if;
 if not exists(select 1 from app.ph_benefit_year where organization_id=p_org and user_id=p_user and tax_year=2026 and opening_through<p_period)
 then raise exception 'reviewed benefit opening required' using errcode='P0001'; end if;
 select count(*)::int,coalesce(sum(x.taxable),0),coalesce(sum(x.withholding),0),max(x.period_start)
 into n,prev_taxable,prev_tax,last_period from app.ph_effective_monetary x where organization_id=p_org and user_id=p_user and extract(year from x.pay_date)=2026 and x.period_start<p_period;
 if (n=0 and p_period<>o.first_period) or (n>0 and p_period<>last_period+7) then raise exception 'noncontiguous payroll history' using errcode='P0001'; end if;
 if exists(select 1 from app.ph_benefit_event b2 where b2.organization_id=p_org and b2.user_id=p_user and b2.tax_year=2026 and b2.paid_on<p_period and not exists(select 1 from app.ph_effective_monetary x where x.organization_id=p_org and x.user_id=p_user and b2.paid_on between x.period_start and x.pay_date)) then raise exception 'unreconciled earlier benefit' using errcode='P0001'; end if;
 select locked_at into known_at from public.payroll_periods where organization_id=p_org and period_start=p_period;
 select count(*) into salary_days from generate_series(p_period,pd,interval '1 day') g where exists(select 1 from app.ph_workday_evidence e2 join app.ph_employment_history eh on (eh.organization_id,eh.user_id,eh.effective_on,eh.recorded_at)=(e2.organization_id,e2.user_id,e2.employment_effective_on,e2.employment_recorded_at) where e2.organization_id=p_org and e2.user_id=p_user and e2.period_start=p_period and e2.work_date=g::date and eh.pay_basis='monthly');
 if salary_days>0 then
 if salary_days<>7 then raise exception 'monthly salary requires seven attested days' using errcode='P0001'; end if;
 salary_mode:=true;
 for d in select generate_series(p_period,pd,interval '1 day')::date loop
 h:=app.ph_reviewed_month_salary(p_org,p_user,d,known_at);
 if not exists(select 1 from app.ph_workday_evidence e2 where e2.organization_id=p_org and e2.user_id=p_user and e2.period_start=p_period and e2.work_date=d and e2.employment_effective_on=h.effective_on and e2.employment_recorded_at=h.recorded_at) then raise exception 'sealed salary revision mismatch' using errcode='P0001'; end if;
 base_amount:=app.ph_salary_calendar_allocation(h.rate_php,d);
 raw_gross:=raw_gross+base_amount;lines:=lines||jsonb_build_array(jsonb_build_object('date',d,'code','guaranteed_salary','amount',base_amount,'employmentRevision',h.recorded_at));
 end loop;
 end if;
 for l in select value from jsonb_array_elements(s.reconciliation->'payLines') loop
 select eh.* into h from app.ph_workday_evidence e join app.ph_employment_history eh on (eh.organization_id,eh.user_id,eh.effective_on,eh.recorded_at)=(e.organization_id,e.user_id,e.employment_effective_on,e.employment_recorded_at)
 where e.organization_id=p_org and e.period_start=p_period and e.user_id=p_user and e.work_date=(l->>'workday')::date;
 if not found or h.status<>'employed' then raise exception 'historical pay evidence missing' using errcode='P0001'; end if;
 if h.pay_basis='hourly' then hourly:=h.rate_php;
 elsif h.pay_basis='daily' then hourly:=h.rate_php/8;
 elsif h.pay_basis='monthly' then
 perform app.ph_approved_evidence(p_org,p_user,'divisor',h.effective_on);
 select * into dv from app.ph_salary_divisor_evidence where (organization_id,user_id,effective_on,recorded_at)=(h.organization_id,h.user_id,h.effective_on,h.recorded_at);
 if not found then raise exception 'reviewed salary divisor missing' using errcode='P0001'; end if;
 hourly:=h.rate_php*12/dv.annual_paid_days/8;
 else raise exception 'unsupported basis' using errcode='22023'; end if;
 factor:=(l->>'multiplier')::numeric;
 if h.pay_basis='monthly' then
 if not salary_mode then raise exception 'reviewed guaranteed salary coverage required' using errcode='P0001'; end if;
 if (l->>'code') not like '%_OT%' then factor:=factor-1; end if;
 end if;
 line_amount:=hourly*(l->>'seconds')::numeric/3600*factor;
 raw_gross:=raw_gross+line_amount;
 lines:=lines||jsonb_build_array(l||jsonb_build_object('hourlyRate',hourly,'unroundedAmount',line_amount,'employmentRevision',h.recorded_at));
 end loop;
 -- Paid nonwork: only independently attested zero-work dates in the sealed roster.
 for l in select value from jsonb_array_elements(a.payload->'nonwork') loop
 d:=(l->>'date')::date; minutes:=(l->>'minutes')::numeric;
 if d is null or d not between p_period and pd or d=any(seen) or minutes is null or minutes<=0 or minutes>480 or minutes<>trunc(minutes)
 or l->>'kind' is null or l->>'kind' not in ('paid_leave','paid_regular_holiday') or length(btrim(coalesce(l->>'reference','')))<8
 or exists(select 1 from jsonb_array_elements(s.reconciliation->'payLines') x where (x->>'date')::date=d or (x->>'workday')::date=d)
 then raise exception 'invalid or overlapping paid nonwork' using errcode='22023'; end if;
 select * into ev_day from app.ph_workday_evidence where organization_id=p_org and user_id=p_user and period_start=p_period and work_date=d;
 if not found or (l->>'kind'='paid_regular_holiday' and coalesce(ev_day.calendar_classes->>d::text,'') not in ('regular_holiday','regular_holiday_rest')) then raise exception 'nonwork calendar evidence missing' using errcode='P0001'; end if;
 select * into h from app.ph_employment_history where (organization_id,user_id,effective_on,recorded_at)=(ev_day.organization_id,ev_day.user_id,ev_day.employment_effective_on,ev_day.employment_recorded_at);
 if l->>'kind'='paid_leave' then
 select * into allocation from app.ph_paid_leave_allocation where organization_id=p_org and user_id=p_user and period_start=p_period and work_date=d;
 if not found or allocation.minutes<>minutes or allocation.request_id is distinct from (l->>'requestId')::uuid then raise exception 'approved paid leave allocation required' using errcode='P0001'; end if;
 select -days*480 into req from public.leave_transactions where request_id=allocation.request_id and organization_id=p_org and user_id=p_user and kind='usage';
 select sum(x.minutes) into used from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.request_id=allocation.request_id;
 if req is null or used is distinct from req then raise exception 'incomplete approved leave allocation' using errcode='P0001'; end if;
 end if;
 if h.pay_basis='hourly' then hourly:=h.rate_php; line_amount:=hourly*minutes/60;
 elsif h.pay_basis='daily' then hourly:=h.rate_php/8; line_amount:=hourly*minutes/60;
 elsif h.pay_basis='monthly' and salary_mode then line_amount:=0;
 else raise exception 'paid nonwork salary basis requires separate review' using errcode='P0001'; end if; raw_gross:=raw_gross+line_amount; seen:=array_append(seen,d);
 lines:=lines||jsonb_build_array(l||jsonb_build_object('unroundedAmount',line_amount,'employmentRevision',h.recorded_at));
 end loop;
 if exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.period_start=p_period and not(x.work_date=any(seen))) then raise exception 'unreconciled paid leave day' using errcode='P0001'; end if;
 if exists(select 1 from public.approval_requests q where q.organization_id=p_org and q.requester_id=p_user and q.kind='leave' and q.status='approved'
 and (q.payload->>'start')::date<=pd and (q.payload->>'end')::date>=p_period
 and not exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.period_start=p_period and x.request_id=q.id))
 then raise exception 'approved leave requires classified allocation' using errcode='P0001'; end if;
 for l in select value from jsonb_array_elements(a.payload->'supplemental') loop
 line_amount:=(l->>'amount')::numeric;
 if l->>'code' is null or l->>'code' not in ('commission','taxable_allowance','other_taxable') or line_amount is null or line_amount<0 or line_amount>1000000000 or line_amount<>round(line_amount,2) or length(btrim(coalesce(l->>'reference','')))<8 then raise exception 'invalid supplemental evidence' using errcode='22023'; end if;
 raw_gross:=raw_gross+line_amount;lines:=lines||jsonb_build_array(l);
 end loop;
 gross:=round(raw_gross,2);
 for b in select * from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=2026 and paid_on between p_period and pd order by sequence_no loop
 gross:=gross+(b.result->>'gross')::numeric;
 exempt:=exempt+(b.result->>'gross')::numeric-(b.result->>'taxable')::numeric;
 lines:=lines||jsonb_build_array(jsonb_build_object('benefitEvent',b.event_key,'result',b.result));
 end loop;
 mon:=date_trunc('month',pd::timestamp)::date;
 select * into m from app.ph_monthly_basis_evidence where organization_id=p_org and user_id=p_user and month_start=mon;
 if not found then raise exception 'reviewed monthly agency bases missing' using errcode='P0001'; end if;
 perform app.ph_approved_evidence(p_org,p_user,'month',mon);
 if p_period>m.allocation_period and not exists(select 1 from app.ph_effective_monetary where organization_id=p_org and user_id=p_user and period_start=m.allocation_period) then raise exception 'missing monthly allocation' using errcode='P0001'; end if;
 if p_period=m.allocation_period then
 foreach agency in array array['sss','philhealth','pagibig'] loop
 basis:=case agency when 'sss' then m.sss_basis when 'philhealth' then m.philhealth_basis else m.pagibig_basis end;
 v:=app.ph_contribution_candidate(agency,basis,mon);
 ee:=ee+(v->>'employee')::numeric;er:=er+(v->>'employer')::numeric;
 contrib:=contrib||jsonb_build_object(agency,v);
 end loop;
 end if;
 if gross-exempt<ee then raise exception 'insufficient compensation for contribution allocation' using errcode='P0001'; end if;
 taxable:=gross-exempt-ee;
 if prior->>'method'='cumulative' then
 j:=app.ph_cumulative_withholding(prev_taxable+taxable+(prior->>'taxable')::numeric,n+1+(prior->>'periods')::int,prev_tax+(prior->>'withheld')::numeric,'weekly',pd);
 else
 j:=jsonb_build_object('withhold',app.ph_tax_candidate(taxable,'weekly',pd),'method','weekly');
 end if;
 tax:=(j->>'withhold')::numeric;
 if tax>taxable then raise exception 'insufficient compensation for withholding' using errcode='P0001'; end if;
 net:=taxable+exempt-tax;
 total:=gross+er;
 journal:=app.ph_canonical_payroll_lines(gross,ee,er,tax,net,contrib);
 v:=jsonb_build_object('earnings',lines,'contributions',contrib,'cumulative',j,'openingEvidence',o.evidence,'basisEvidence',m.evidence,'method','ph-weekly-2026-reviewed-candidate','prior',prior,'attestation',a.id,'exempt',exempt);
 insert into app.ph_monetary_snapshot(organization_id,period_start,user_id,pay_date,gross,employee_contributions,employer_contributions,taxable,withholding,net,evidence,posted_by,exempt,revision)
 values(p_org,p_period,p_user,pd,gross,ee,er,taxable,tax,net,v,auth.uid(),exempt,version_no);
 insert into app.ph_payroll_journal values(p_org,p_period,p_user,journal,total,total,version_no);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),case when p_replay then 'accounting.ph_week_replayed' else 'accounting.ph_monetary_snapshot' end,'membership',p_user::text,jsonb_build_object('periodStart',p_period));
 return jsonb_build_object('gross',gross,'exempt',exempt,'employeeContributions',ee,'employerContributions',er,'taxable',taxable,'withholding',tax,'net',net,'journalTotal',total,'revision',version_no);
end $$;
create or replace function app.ph_post_cutoff_version(p_org uuid,p_user uuid,p_start date,p_replay boolean)
returns jsonb language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;o app.ph_payroll_attestation;wa app.ph_payroll_attestation;ca app.ph_payroll_attestation;
 h app.ph_employment_history; dv app.ph_salary_divisor_evidence; reviewed app.ph_employment_history; first_h app.ph_employment_history;ev app.ph_workday_evidence;z app.accounting_locked_snapshot;
 old app.ph_monetary_snapshot;y app.ph_benefit_year;b app.ph_benefit_event;original app.ph_monetary_snapshot; version_no int;
 freq text;e date;d date;wk date;mon date;alloc date;line jsonb;code text;nonwork jsonb;actual_ids jsonb;
 worked numeric;secs numeric;rate numeric;factor numeric;amount numeric;wage numeric;is_mwe boolean;any_mwe boolean:=false;any_non_mwe boolean:=false;
 basic numeric:=0;premium numeric:=0;qualifying numeric:=0;raw_basic numeric:=0;raw_premium numeric:=0;raw_exempt numeric:=0;
 extra numeric;hazard numeric;bg numeric:=0;be numeric:=0;gross numeric;exempt numeric;taxable numeric;ded numeric;ee numeric:=0;er numeric:=0;wt numeric;
 prior jsonb;pt numeric;pw numeric;n int;last_end date;sticky boolean;use_average boolean;avg_result jsonb;
 s jsonb;ph jsonb;f jsonb;contrib jsonb;calc jsonb;lines jsonb:='[]';bal numeric;regtax numeric;supptax numeric; maternity app.ph_statutory_journal; month_split jsonb; maternity_day boolean; ordinary_basic numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 if p_start is null or p_start not between date '2026-01-06' and date '2026-11-24' then raise exception 'unsupported payroll date' using errcode='22023';end if;

 if p_replay is null then raise exception 'posting mode required' using errcode='22023';end if;
 version_no:=case when p_replay then 2 else 1 end;
 a:=app.ph_approved_evidence(p_org,p_user,case when p_replay then 'replay' else 'period' end,p_start);
 if a.maker=auth.uid() then raise exception 'maker cannot post' using errcode='42501';end if;
 if exists(select 1 from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'closed payroll' using errcode='P0001';end if;
 if p_replay then
 select * into original from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_start and revision=1;
 if not found or original.frequency not in ('daily','semi-monthly','monthly') or a.payload->>'originalAttestation' is distinct from original.evidence->>'attestation'
 or not exists(select 1 from app.ph_canonical_reversal where organization_id=p_org and user_id=p_user and period_start=p_start)
 or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start>p_start)
 then raise exception 'latest reversed original required' using errcode='P0001';end if;
 if (a.payload - array['reason','undispatched','originalAttestation','taxableExtras']) is distinct from ((app.ph_approved_evidence(p_org,p_user,'period',p_start)).payload - 'taxableExtras') then raise exception 'unsupported replacement scope' using errcode='P0001';end if;
 else
 if app.ph_unresolved_reversal(p_org,p_user) or exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_start and revision=2) then raise exception 'reversed or replaced cutoff' using errcode='P0001';end if;
 end if;
 select * into old from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=p_start and revision=version_no;
 if found then
 if old.evidence->>'attestation' is distinct from a.id::text then raise exception 'posting conflict' using errcode='P0001';end if;return old.evidence;end if;
 o:=app.ph_approved_evidence(p_org,p_user,'cutoff_opening','2026-01-01');
 freq:=o.payload->>'frequency';e:=app.ph_period_end(p_start,freq);
 if e>date '2026-11-24' or (a.payload->>'end')::date is distinct from e or a.payload->>'frequency' is distinct from freq then raise exception 'period or frequency mismatch' using errcode='22023';end if;

 select * into maternity from app.ph_statutory_journal where organization_id=p_org and user_id=p_user and category='maternity_contribution' and covered_from<=e and covered_to>=p_start;
 if found then
 if p_replay or freq<>'monthly' or a.payload->>'maternityAllocation' is distinct from maternity.attestation_id::text then raise exception 'reviewed monthly maternity allocation required' using errcode='P0001';end if;
 select x into month_split from jsonb_array_elements(maternity.result->'contributionMonths') x where (x->>'month')::date=p_start;
 if month_split is null then raise exception 'maternity month allocation missing' using errcode='P0001';end if;
 ordinary_basic:=(month_split->>'ordinaryBasic')::numeric;
 elsif exists(select 1 from app.ph_statutory_journal x where x.organization_id=p_org and x.user_id=p_user and x.category='maternity_advance' and x.covered_from<=e and x.covered_to>=p_start) then raise exception 'maternity contribution journal required' using errcode='P0001';
 elsif a.payload ? 'maternityAllocation' then raise exception 'unexpected maternity allocation' using errcode='P0001';end if;
 -- Candidate pay date is end of cutoff. Frequency fixed for year; no overlap/gap.
 select count(*) filter(where m.gross>0)::int,coalesce(sum(m.taxable),0),coalesce(sum(m.withholding),0),max(m.pay_date),
 coalesce(bool_or((m.evidence->>'cumulative')::boolean),false)
 into n,pt,pw,last_end,sticky from app.ph_effective_monetary m
 where m.organization_id=p_org and m.user_id=p_user and extract(year from m.period_start)=2026 and m.period_start<p_start;
 if p_start is distinct from coalesce(last_end+1,(o.payload->>'firstPeriod')::date) then raise exception 'noncontiguous period history' using errcode='P0001';end if;
 if o.payload->'certificates' is distinct from '[]'::jsonb or (o.payload->>'previousPeriods')::int<>0 or exists(select 1 from app.ph_2316_import where organization_id=p_org and user_id=p_user and tax_year=2026) then raise exception 'cutoff prior employer requires integration' using errcode='P0001';end if;
 prior:=jsonb_build_object('taxable',0,'withheld',0,'periods',0);
 select * into y from app.ph_benefit_year where organization_id=p_org and user_id=p_user and tax_year=2026;
 if not found or y.opening_through>=(o.payload->>'firstPeriod')::date
 or o.payload->'benefitOpening' is distinct from jsonb_build_object('through',y.opening_through,'buckets',y.opening_buckets,'other',y.opening_other,'medicalMode',y.medical_mode)
 then raise exception 'reviewed benefit opening mismatch' using errcode='P0001';end if;
 if exists(select 1 from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.tax_year=2026 and x.paid_on<p_start
 and not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and x.paid_on between m.period_start and m.pay_date))
 then raise exception 'earlier benefit not reconciled' using errcode='P0001';end if;
 -- Reject minute-only corrections and cross-period spill on either boundary.
 if exists(select 1 from app.accounting_adjustment_proposal q where q.organization_id=p_org and q.user_id=p_user and q.period_start<=e and q.period_start+6>=p_start)
 or exists(select 1 from app.accounting_locked_snapshot q cross join lateral jsonb_array_elements(q.reconciliation->'payLines') l
 where q.organization_id=p_org and q.user_id=p_user and
 (((l->>'workday')::date between p_start and e) is distinct from ((l->>'date')::date between p_start and e)))
 then raise exception 'adjustment or cross-cutoff workday requires allocation review' using errcode='P0001';end if;

 if exists(select 1 from public.approval_requests q where q.organization_id=p_org and q.requester_id=p_user and q.kind='leave' and q.status='approved' and (q.payload->>'start')::date<=e and (q.payload->>'end')::date>=p_start
 and not exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.request_id=q.id and x.work_date between p_start and e)) then raise exception 'cutoff leave requires approved allocation review' using errcode='P0001';end if;
 if exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.work_date between p_start and e and
 ((a.payload->'nonwork'->x.work_date::text->>'kind') is distinct from 'paid_leave' or (a.payload->'nonwork'->x.work_date::text->>'requestId') is distinct from x.request_id::text)) then raise exception 'unreconciled paid leave allocation' using errcode='P0001';end if;
 first_h:=app.ph_employment_as_of(p_org,p_user,p_start,clock_timestamp());
 if first_h.status<>'employed' then raise exception 'historically employed period required' using errcode='P0001';end if;
 if first_h.pay_basis not in ('daily','hourly','monthly') or freq not in ('daily','semi-monthly','monthly') or (first_h.pay_basis='monthly' and freq<>'monthly') then raise exception 'restricted cutoff compensation basis' using errcode='P0001';end if;
 for d in select p_start+i from generate_series(0,e-p_start)i loop
 wk:=d-(extract(isodow from d)::int-1);
 select * into ev from app.ph_workday_evidence where organization_id=p_org and user_id=p_user and work_date=d and period_start=wk;
 if not found then raise exception 'complete workday evidence required' using errcode='P0001';end if;
 h:=app.ph_employment_as_of(p_org,p_user,d,clock_timestamp());
 if h.status<>'employed' or (h.effective_on,h.recorded_at) is distinct from (ev.employment_effective_on,ev.employment_recorded_at)
 or h.pay_basis<>first_h.pay_basis or (h.pay_basis='monthly' and (h.effective_on,h.recorded_at) is distinct from (first_h.effective_on,first_h.recorded_at))
 then raise exception 'employment revision requires review' using errcode='P0001';end if;

 maternity_day:=month_split is not null and d between maternity.covered_from and maternity.covered_to;
 if maternity_day then
 if h.pay_basis<>'monthly' or a.payload->'nonwork'->d::text->>'kind' is distinct from 'maternity_covered'
 or exists(select 1 from app.ph_paid_leave_allocation x where x.organization_id=p_org and x.user_id=p_user and x.work_date=d)
 or not exists(select 1 from app.accounting_locked_snapshot q where q.organization_id=p_org and q.user_id=p_user and q.period_start=wk and q.reconciliation->>'classificationVersion'='4' and (q.reconciliation->>'exactOvertimeReviewSeconds')::numeric=0 and not exists(select 1 from jsonb_array_elements(q.reconciliation->'payLines') l where (l->>'workday')::date=d or (l->>'date')::date=d))
 then raise exception 'maternity day coverage conflicts with ordinary payroll' using errcode='P0001';end if;
 lines:=lines||jsonb_build_array(jsonb_build_object('date',d,'kind','maternity_covered','allocation',maternity.attestation_id));
 continue;
 end if;
 wa:=app.ph_wage_on(p_org,p_user,d,h.site_reference,h.wage_order_reference);
 wage:=(wa.payload->>'dailyMinimum')::numeric;

 if h.pay_basis='monthly' then
 reviewed:=app.ph_reviewed_month_salary(p_org,p_user,d,clock_timestamp());
 if (reviewed.effective_on,reviewed.recorded_at) is distinct from (h.effective_on,h.recorded_at) then raise exception 'reviewed monthly salary mismatch' using errcode='P0001';end if;
 perform app.ph_approved_evidence(p_org,p_user,'divisor',h.effective_on);
 select * into dv from app.ph_salary_divisor_evidence where (organization_id,user_id,effective_on,recorded_at)=(h.organization_id,h.user_id,h.effective_on,h.recorded_at);
 if not found then raise exception 'reviewed monthly salary divisor required' using errcode='P0001';end if;
 rate:=h.rate_php*12/dv.annual_paid_days/8;
 else rate:=case h.pay_basis when 'hourly' then h.rate_php when 'daily' then h.rate_php/8 else null end;end if;

 -- Compare without floating-point. Monthly MWE and unusual coverage require separate review.
 if rate*8<wage or (h.pay_basis='monthly' and rate*8<=wage) then raise exception 'wage underpayment or unsupported monthly MWE' using errcode='P0001';end if;
 is_mwe:=rate*8=wage;any_mwe:=any_mwe or is_mwe;any_non_mwe:=any_non_mwe or not is_mwe;
 select * into z from app.accounting_locked_snapshot where organization_id=p_org and user_id=p_user and period_start=wk;
 if not found or z.reconciliation->>'classificationVersion' is distinct from '4'
 or coalesce((z.reconciliation->>'exactOvertimeReviewSeconds')::numeric,1)<>0
 or not exists(select 1 from public.payroll_periods where organization_id=p_org and period_start=wk)
 then raise exception 'locked exact attendance required' using errcode='P0001';end if;
 worked:=0;
 for line in select l from jsonb_array_elements(z.reconciliation->'payLines') l where (l->>'workday')::date=d loop
 secs:=(line->>'seconds')::numeric;factor:=(line->>'multiplier')::numeric;code:=line->>'code';
 if secs is null or secs<=0 or secs>86400 or factor is null or factor<1 or factor>10 or code is null or code !~ '^(REG|RD|SH|SH_RD|RH|RH_RD|DH|DH_RD)(_OT)?(_ND)?$'
 then raise exception 'invalid exact pay line' using errcode='P0001';end if;
 if is_mwe and code !~ '^(REG|RH|RH_RD|DH|DH_RD)(_OT)?(_ND)?$' then raise exception 'MWE rest/special-day exemption needs separate review' using errcode='P0001';end if;
 worked:=worked+secs;
 if code~'(^|_)OT(_|$)' then
 amount:=rate*secs/3600*factor;raw_premium:=raw_premium+amount;
 else
 amount:=rate*secs/3600*factor;
 if h.pay_basis='monthly' then raw_premium:=raw_premium+rate*secs/3600*(factor-1);
 else raw_basic:=raw_basic+rate*secs/3600;raw_premium:=raw_premium+rate*secs/3600*(factor-1);end if;
 end if;
 if is_mwe then raw_exempt:=raw_exempt+amount;end if;
 lines:=lines||jsonb_build_array(line||jsonb_build_object('hourlyRate',rate,'wageEvidence',wa.id,'employmentRevision',h.recorded_at));
 end loop;
 if worked>86400 then raise exception 'invalid total workday seconds' using errcode='P0001';end if;
 nonwork:=a.payload->'nonwork'->d::text;
 if worked>0 and nonwork is not null then raise exception 'overlapping nonwork payment' using errcode='P0001';end if;
 if worked=0 then
 if nonwork is null or jsonb_typeof(nonwork)<>'object' or length(btrim(coalesce(nonwork->>'reference','')))<8 then raise exception 'zero-work date requires disposition' using errcode='P0001';end if;
 if nonwork->>'kind' not in ('paid_leave','paid_regular_holiday','unpaid_nonwork','monthly_covered') or nonwork->>'kind' is null then raise exception 'unsupported nonwork disposition' using errcode='22023';end if;
 if nonwork->>'kind'='paid_regular_holiday' and coalesce(ev.calendar_classes->>d::text,'') not in ('regular_holiday','regular_holiday_rest') then raise exception 'holiday evidence mismatch' using errcode='P0001';end if;
 if h.pay_basis='monthly' and nonwork->>'kind' not in ('monthly_covered','paid_leave') then raise exception 'partial monthly salary requires separate review' using errcode='P0001';end if;
 if h.pay_basis<>'monthly' and nonwork->>'kind'='monthly_covered' then raise exception 'invalid monthly coverage' using errcode='P0001';end if;
 if nonwork->>'kind' in ('paid_leave','paid_regular_holiday') then
 
 if nonwork->>'kind'='paid_leave' then
 if is_mwe or coalesce(ev.calendar_classes->>d::text,'')<>'ordinary' then raise exception 'MWE or nonordinary leave classification needs review' using errcode='P0001';end if;
 amount:=rate*app.ph_cutoff_leave_minutes(p_org,p_user,p_start,e,d,nonwork)/60;
 if h.pay_basis='monthly' then amount:=0;end if;
 else amount:=rate*8;end if;
 raw_basic:=raw_basic+amount;if is_mwe then raw_exempt:=raw_exempt+amount;end if;
 end if;
 lines:=lines||jsonb_build_array(nonwork||jsonb_build_object('date',d,'wageEvidence',wa.id,'employmentRevision',h.recorded_at));
 end if;
 end loop;
 if any_mwe and any_non_mwe then raise exception 'MWE status changed within period' using errcode='P0001';end if;
 if exists(select 1 from jsonb_object_keys(a.payload->'nonwork') k where k::date not between p_start and e) then raise exception 'nonwork date outside cutoff' using errcode='22023';end if;
 if first_h.pay_basis='monthly' then
 if freq='monthly' then raw_basic:=coalesce(ordinary_basic,first_h.rate_php);
 elsif extract(day from p_start)=1 then raw_basic:=round(first_h.rate_php/2,2);
 else raw_basic:=first_h.rate_php-round(first_h.rate_php/2,2);end if;end if;
 basic:=round(raw_basic,2);premium:=round(raw_basic+raw_premium,2)-basic;
 qualifying:=round(raw_exempt,2);
 extra:=(a.payload->>'taxableExtras')::numeric;hazard:=(a.payload->>'hazardPay')::numeric;
 for b in select * from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=2026 and paid_on between p_start and e order by sequence_no loop
 bg:=bg+(b.result->>'gross')::numeric;be:=be+(b.result->>'gross')::numeric-(b.result->>'taxable')::numeric;
 lines:=lines||jsonb_build_array(jsonb_build_object('benefitEvent',b.event_key,'result',b.result));
 end loop;
 select coalesce(jsonb_agg(event_key order by event_key),'[]') into actual_ids from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=2026 and paid_on between p_start and e;
 if actual_ids is distinct from a.payload->'benefitKeys' then raise exception 'reviewed benefit set changed' using errcode='P0001';end if;

 if month_split is not null and (first_h.pay_basis<>'monthly' or any_mwe or (ordinary_basic=0 and (premium+extra+hazard+bg)<>0)
 or exists(select 1 from app.ph_benefit_event x where x.organization_id=p_org and x.user_id=p_user and x.paid_on between greatest(p_start,maternity.covered_from) and least(e,maternity.covered_to))) then raise exception 'unsupported maternity month compensation' using errcode='P0001';end if;
 gross:=basic+premium+extra+hazard+bg;
 exempt:=qualifying+be+case when any_mwe then hazard else 0 end;
 -- Monthly contribution bases are independently reviewed and allocated once
 -- to an exact payment date; no estimated or repeated deduction. Pay-month
 -- boundaries use payment date, not shift start. Partial/employer exemptions unsupported.
 mon:=date_trunc('month',e)::date;ca:=app.ph_approved_evidence(p_org,p_user,'contribution',mon);
 alloc:=(ca.payload->>'allocationDate')::date;
 if e<alloc and date_trunc('month',app.ph_period_end(e+1,freq))::date<>mon
 then raise exception 'final monthly cutoff cannot leave contributions unallocated' using errcode='P0001';end if;
 if e>alloc and not exists(select 1 from app.ph_effective_monetary m where m.organization_id=p_org and m.user_id=p_user and m.pay_date=alloc and m.evidence->>'contributionEvidence'=ca.id::text)
 then raise exception 'monthly contribution allocation missed' using errcode='P0001';end if;
 if e=alloc then
 s:=app.ph_contribution_candidate('sss',(ca.payload->>'sss')::numeric,mon);
 ph:=app.ph_contribution_candidate('philhealth',(ca.payload->>'philhealth')::numeric,mon);
 f:=app.ph_contribution_candidate('pagibig',(ca.payload->>'pagibig')::numeric,mon);

 if month_split is not null then
 if month_split->>'contributionAttestation' is distinct from ca.id::text then raise exception 'maternity agency evidence changed' using errcode='P0001';end if;
 s:=app.ph_ordinary_contribution_residual(s,month_split->'maternityShares'->'sss');
 ph:=app.ph_ordinary_contribution_residual(ph,month_split->'maternityShares'->'philhealth');
 f:=app.ph_ordinary_contribution_residual(f,month_split->'maternityShares'->'pagibig');
 end if;
 ee:=(s->>'employee')::numeric+(ph->>'employee')::numeric+(f->>'employee')::numeric;
 er:=(s->>'employer')::numeric+(ph->>'employer')::numeric+(f->>'employer')::numeric;
 end if;
 ded:=(a.payload->>'taxDeductible')::numeric;
 if ded>least(ee,gross-exempt) or (not any_mwe and ded<>least(ee,gross-exempt)) then raise exception 'tax-deductible statutory contributions require review' using errcode='P0001';end if;
 taxable:=gross-exempt-ded;
 -- Mandatory cumulative switch for supplemental pay at/above regular taxable,
 -- or when regular taxable is below the periodic floor; sticky for the year.
 regtax:=greatest(0,basic-qualifying-ded);
 supptax:=greatest(0,taxable-regtax);
 use_average:=sticky or (prior->>'periods')::int>0 or (a.payload->>'cumulative')::boolean
 or (supptax>0 and (supptax>=regtax or app.ph_tax_candidate(regtax,freq,e)=0));
 if gross=0 then wt:=0;
 elsif use_average then
 avg_result:=app.ph_cumulative_withholding(pt+taxable+(prior->>'taxable')::numeric,n+1+(prior->>'periods')::int,pw+(prior->>'withheld')::numeric,freq,e);
 wt:=(avg_result->>'withhold')::numeric;
 else wt:=app.ph_tax_candidate(taxable,freq,e);end if;
 if gross-ee-wt<0 then raise exception 'insufficient compensation; separate reviewed settlement required' using errcode='P0001';end if;
 if month_split is not null and e<>alloc then raise exception 'monthly residual allocation date mismatch' using errcode='P0001';end if;
 calc:=jsonb_build_object('sourceVersion',2,'revision',version_no,'frequency',freq,'periodStart',p_start,'periodEnd',e,'payDate',e,'basic',basic,'premium',premium,
 'gross',gross,'exempt',exempt,'mweExempt',qualifying+case when any_mwe then hazard else 0 end,'employeeContrib',ee,'employerContrib',er,
 'taxDeductible',ded,'taxable',taxable,'withholding',wt,'net',gross-ee-wt,'employerCost',gross+er,'benefitKeys',actual_ids,
 'contributions',jsonb_build_object('sss',s,'philhealth',ph,'pagibig',f),'sss',s,'philhealth',ph,'pagibig',f,'contributionEvidence',ca.id,'priorEmployer',prior,'cumulative',use_average,'averageEvidence',avg_result,'lines',lines,'attestation',a.id);

 if month_split is not null then calc:=calc||jsonb_build_object('maternityAllocation',maternity.attestation_id,'maternityCoveredDays',month_split->'coveredDays','fullAgencyBasis',month_split->'agencies');end if;
 insert into app.ph_monetary_snapshot(organization_id,period_start,user_id,pay_date,gross,employee_contributions,employer_contributions,taxable,withholding,net,evidence,posted_by,exempt,frequency,tax_deductible,revision)
 values(p_org,p_start,p_user,e,gross,ee,er,taxable,wt,gross-ee-wt,calc,auth.uid(),exempt,freq,ded,version_no);
 lines:=app.ph_canonical_payroll_lines(gross,ee,er,wt,gross-ee-wt,jsonb_build_object('sss',s,'philhealth',ph,'pagibig',f));
 insert into app.ph_payroll_journal values(p_org,p_start,p_user,lines,gross+er,gross+er,version_no);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),case when p_replay then 'accounting.ph_cutoff_replayed' else 'accounting.ph_cutoff_posted' end,'membership',p_user::text,jsonb_build_object('periodStart',p_start,'periodEnd',e,'frequency',freq));
 return calc;
end $$;
-- Verify the actual immutable row, not just its declared balanced totals.
create function app.ph_verify_payroll_journal() returns trigger
language plpgsql set search_path='' as $$
declare s app.ph_monetary_snapshot; expected jsonb;
begin
 perform app.accounting_tenant_lock(new.organization_id);
 select * into strict s from app.ph_monetary_snapshot where (organization_id,period_start,user_id,revision)=(new.organization_id,new.period_start,new.user_id,new.revision);
 if extract(year from s.pay_date)=2026 then
 expected:=app.ph_canonical_payroll_lines(s.gross,s.employee_contributions,s.employer_contributions,s.withholding,s.net,s.evidence->'contributions');
 if new.lines is distinct from expected or new.debit_total<>s.gross+s.employer_contributions or new.credit_total<>new.debit_total
 then raise exception 'journal does not match canonical snapshot' using errcode='22023';end if;
 end if;
 return new;
end $$;
create trigger p15_verify_journal before insert on app.ph_payroll_journal for each row execute function app.ph_verify_payroll_journal();
revoke all on function app.ph_verify_payroll_journal() from public,anon,authenticated,service_role;

-- PR21's component-level SSS reconciliation, projected from the effective
-- canonical revision. This is a private review, not a second payable account.
create function app.ph_review_sss_components(p_org uuid,p_month date)
returns jsonb language plpgsql set search_path='' as $$
declare r record; x jsonb; reg numeric:=0; mpf numeric:=0; ec numeric:=0; total numeric:=0; n int:=0;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock')
 then raise exception 'forbidden' using errcode='42501';end if;
 if p_month is null or extract(day from p_month)<>1 or extract(year from p_month)<>2026
 or (p_month+interval '1 month')::date>date '2026-11-24'
 then raise exception 'closed supported month required' using errcode='22023';end if;
 if exists(select 1 from app.ph_canonical_reversal v join app.ph_monetary_snapshot s
 on (s.organization_id,s.user_id,s.period_start,s.revision)=(v.organization_id,v.user_id,v.period_start,1)
 where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<(p_month+interval '1 month')::date
 and not exists(select 1 from app.ph_effective_monetary e where (e.organization_id,e.user_id,e.period_start,e.revision)=(s.organization_id,s.user_id,s.period_start,2)))
 then raise exception 'unresolved reversal' using errcode='P0001';end if;
 for r in select s.evidence,j.lines from app.ph_effective_monetary s join app.ph_payroll_journal j using(organization_id,user_id,period_start,revision)
 where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<(p_month+interval '1 month')::date loop
 n:=n+1;x:=r.evidence->'contributions'->'sss';
 if x is not null and x<>'null'::jsonb then
 if not app.ph_stat_money((x->>'employeeRegular')::numeric) or not app.ph_stat_money((x->>'employerRegular')::numeric)
 or not app.ph_stat_money((x->>'employeeMpf')::numeric) or not app.ph_stat_money((x->>'employerMpf')::numeric)
 or not app.ph_stat_money((x->>'employerEc')::numeric) then raise exception 'missing SSS split' using errcode='P0001';end if;
 reg:=reg+(x->>'employeeRegular')::numeric+(x->>'employerRegular')::numeric;
 mpf:=mpf+(x->>'employeeMpf')::numeric+(x->>'employerMpf')::numeric;
 ec:=ec+(x->>'employerEc')::numeric;
 end if;
 total:=total+coalesce((select sum((l->>'credit')::numeric-(l->>'debit')::numeric) from jsonb_array_elements(r.lines) l where l->>'account'='sss_payable'),0);
 end loop;
 if n=0 or reg+mpf+ec<>total then raise exception 'SSS liability does not reconcile' using errcode='P0001';end if;
 return jsonb_build_object('regular',reg,'mpf',mpf,'ec',ec,'total',total,'periodCount',n,'coverageComplete',false,'officialUpload',false);
end $$;
revoke all on function app.ph_review_sss_components(uuid,date) from public,anon,authenticated,service_role;
