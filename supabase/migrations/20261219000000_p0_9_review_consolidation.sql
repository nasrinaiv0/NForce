-- Selective PR20 port: existing evidence and existing benefit arithmetic only.
alter table app.ph_payroll_attestation drop constraint ph_payroll_attestation_kind_check;
alter table app.ph_payroll_attestation add check(kind in ('opening','period','wage','contribution','annual','replay','statutory_quote'));
create or replace function app.ph_approve_payroll_evidence(p_org uuid,p_id uuid,p_ref text)
returns void language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; d app.ph_payroll_attestation_decision;y jsonb;v numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 select * into a from app.ph_payroll_attestation where organization_id=p_org and id=p_id;
 if not found or auth.uid() in(a.maker,a.user_id) then raise exception 'independent checker required' using errcode='42501';end if;
 select * into d from app.ph_payroll_attestation_decision where attestation_id=a.id;
 if found then
 if (d.checker,d.evidence) is distinct from (auth.uid(),p_ref) then raise exception 'attestation review conflict' using errcode='22023';end if;
 return;end if;
 y:=a.payload;
 case a.kind
 when 'wage' then
 if y->>'region' is null or y->>'region' not in ('NCR','CAR','I','II','III','IV-A','IV-B','V','VI','VII','VIII','IX','X','XI','XII','XIII','NIR','BARMM')
 or length(btrim(coalesce(y->>'locality','')))<2 or length(btrim(coalesce(y->>'sector','')))<2 or length(btrim(coalesce(y->>'coverage','')))<8
 or length(btrim(coalesce(y->>'site','')))<1 or length(btrim(coalesce(y->>'order','')))<1
 or coalesce(y->>'source','') !~ '^https://(nwpc[.]dole[.]gov[.]ph|mole[.]bangsamoro[.]gov[.]ph)/'
 or coalesce(y->>'documentSha256','') !~ '^[a-f0-9]{64}$'
 or (y->>'through')::date is null or (y->>'through')::date<a.scope_date or (y->>'through')::date>date '2026-11-24'
 or not app.ph_stat_money((y->>'dailyMinimum')::numeric) or (y->>'dailyMinimum')::numeric<=0
 then raise exception 'complete reviewed wage-order category and source required' using errcode='22023';end if;
 when 'opening' then
 if a.scope_date<>date '2026-01-01' or y->>'frequency' is null or y->>'frequency' not in ('daily','weekly','semi-monthly','monthly')
 or (y->>'firstPeriod')::date is null or (y->>'firstPeriod')::date not between date '2026-01-06' and date '2026-11-24'
 or (y->>'currentStart')::date is distinct from (y->>'firstPeriod')::date
 or jsonb_typeof(y->'certificates') is distinct from 'array'
 or (y->>'previousPeriods')::integer is null or (y->>'previousPeriods')::integer<0
 or jsonb_typeof(y->'benefitOpening') is distinct from 'object'
 or y->>'completeCurrentYtd' is distinct from 'true'
 then raise exception 'complete reviewed opening required' using errcode='22023';end if;
 when 'period','replay' then
 if (y->>'end')::date is null or (y->>'end')::date<a.scope_date or (y->>'end')::date>date '2026-11-24'
 or y->>'frequency' is null or y->>'frequency' not in ('daily','weekly','semi-monthly','monthly')
 or y->>'coverage' is distinct from 'ordinary-covered-complete'
 or jsonb_typeof(y->'nonwork') is distinct from 'object'
 or jsonb_typeof(y->'benefitKeys') is distinct from 'array'
 or y->>'cumulative' is null or y->>'cumulative' not in ('true','false')
 or not app.ph_stat_money((y->>'taxDeductible')::numeric)
 or not app.ph_stat_money((y->>'taxableExtras')::numeric)
 or not app.ph_stat_money((y->>'hazardPay')::numeric)
 or ((y->>'hazardPay')::numeric>0 and length(btrim(coalesce(y->>'hazardEvidence','')))<8)
 then raise exception 'complete reviewed period evidence required' using errcode='22023';end if;
 if a.kind='replay' and (length(btrim(coalesce(y->>'reason','')))<8 or y->>'undispatched' is distinct from 'true' or y->>'originalAttestation' is null) then raise exception 'reviewed undispatched replay required' using errcode='22023';end if;
 when 'contribution' then
 if extract(day from a.scope_date)<>1 or (y->>'allocationDate')::date is null or date_trunc('month',(y->>'allocationDate')::date)::date<>a.scope_date
 then raise exception 'monthly contribution allocation date required' using errcode='22023';end if;
 foreach v in array array[(y->>'sss')::numeric,(y->>'philhealth')::numeric,(y->>'pagibig')::numeric] loop
 if not app.ph_stat_money(v) or v<=0 then raise exception 'reviewed agency bases required' using errcode='22023';end if;end loop;
 when 'statutory_quote' then
 if y->>'category' is null or y->>'category' not in ('thirteenth','maternity','leave','special_women','separation','retirement')
 or jsonb_typeof(y->'eligible') is distinct from 'boolean' or (y->>'eligible')::boolean is distinct from true
 then raise exception 'reviewed eligibility required' using errcode='22023';end if;
 when 'annual' then
 if y->>'reason' is null or y->>'reason' not in ('termination','year_end')
 or not app.ph_stat_money((y->>'available')::numeric) or y->>'completeFinalCompensation' is distinct from 'true'
 then raise exception 'complete reviewed settlement required' using errcode='22023';end if;
 end case;
 insert into app.ph_payroll_attestation_decision(attestation_id,organization_id,checker,evidence) values(a.id,p_org,auth.uid(),p_ref);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_evidence_approved','attestation',a.id::text,jsonb_build_object('kind',a.kind));
end $$;

create function app.ph_reviewed_statutory_quote(p_org uuid,p_user uuid,p_day date)
returns jsonb language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation; y jsonb; result jsonb;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 a:=app.ph_approved_evidence(p_org,p_user,'statutory_quote',p_day);
 y:=a.payload;
 case y->>'category'
 when 'thirteenth' then result:=app.ph_thirteenth_amount((y->>'basic')::numeric,(y->>'maternity')::numeric,(y->>'integratedBasic')::numeric,(y->>'paid')::numeric,(y->>'eligible')::boolean,a.evidence);
 when 'maternity' then result:=app.ph_maternity_amount(y->>'kind',(y->>'solo')::boolean,(y->>'fullPay')::numeric,(y->>'employeeContributions')::numeric,(y->>'sssActual')::numeric,(y->>'eligible')::boolean,a.evidence);
 when 'leave' then result:=app.ph_leave_amount(y->>'code',(y->>'priorDays')::numeric,(y->>'days')::numeric,(y->>'dailyRate')::numeric,(y->>'serviceMonths')::int,(y->>'eventNo')::int,(y->>'eligible')::boolean,a.evidence);
 when 'special_women' then result:=jsonb_build_object('paidAmount',app.ph_special_women_leave((y->>'monthlyGross')::numeric,(y->>'months')::numeric,(y->>'serviceMonths')::int,(y->>'eligible')::boolean,a.evidence));
 when 'separation' then result:=app.ph_separation_amount(y->>'cause',(y->>'monthlyBase')::numeric,(y->>'serviceMonths')::int,(y->>'eligible')::boolean,a.evidence);
 when 'retirement' then result:=app.ph_retirement_amount((y->>'dailyBase')::numeric,(y->>'serviceMonths')::int,(y->>'age')::int,(y->>'eligible')::boolean,a.evidence);
 else raise exception 'unsupported statutory category' using errcode='22023';
 end case;
 return jsonb_build_object('quoteOnly',true,'attestationId',a.id,'category',y->>'category','result',result);
end $$;
revoke all on function app.ph_reviewed_statutory_quote(uuid,uuid,date) from public,anon,authenticated,service_role;


-- Private internal reconciliation; no statutory filing or proof of completeness.
-- Review totals come from the current effective revisions and exact ledger lines.
-- Include annual journal adjustments separately, not automatic refund offsets.
create function app.ph_month_liability_review(p_org uuid,p_month date)
returns jsonb language plpgsql set search_path='' as $$
declare e date;j jsonb; sources jsonb; adj jsonb; n int; g numeric; ee numeric; er numeric; w numeric; net numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock')
 then raise exception 'forbidden' using errcode='42501';end if;
 if p_month is null or extract(year from p_month)<>2026 or extract(day from p_month)<>1 or (p_month+interval '1 month')::date>date '2026-11-24'
 then raise exception 'closed supported month required' using errcode='22023';end if;
 e:=(p_month+interval '1 month')::date;
 if exists(select 1 from app.ph_money_reversal r join app.ph_money_snapshot x on (r.organization_id,r.user_id,r.pay_month)=(x.organization_id,x.user_id,x.pay_month)
 where r.organization_id=p_org and x.revision=1 and x.pay_date>=p_month and x.pay_date<e
 and not exists(select 1 from app.ph_money_snapshot z where (z.organization_id,z.user_id,z.pay_month,z.revision)=(r.organization_id,r.user_id,r.pay_month,2)))
 then raise exception 'unreplayed reversal requires review' using errcode='P0001';end if;
 select count(*)::int,sum(s.gross),sum(s.employee_contrib),sum(s.employer_contrib),sum(s.withholding),sum(s.net),
 jsonb_agg(jsonb_build_object('employee',s.user_id,'periodStart',s.pay_month,'revision',s.revision,'payDate',s.pay_date) order by s.pay_month,s.user_id)
 into n,g,ee,er,w,net,sources from app.ph_money_active s where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<e;
 if n=0 or g-ee-w<>net then raise exception 'no reconciled effective accruals' using errcode='P0001';end if;
 if exists(select 1 from app.ph_money_active s left join app.ph_money_journal x on (x.organization_id,x.user_id,x.pay_month,x.revision)=(s.organization_id,s.user_id,s.pay_month,s.revision)
 where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<e group by s.organization_id,s.user_id,s.pay_month,s.revision,s.employer_cost
 having coalesce(sum(x.debit),0)<>s.employer_cost or coalesce(sum(x.credit),0)<>s.employer_cost)
 then raise exception 'unbalanced effective journal' using errcode='P0001';end if;
 select coalesce(jsonb_object_agg(q.account_code,q.amount),'{}') into j from (
 select x.account_code,sum(x.credit-x.debit) amount from app.ph_money_active s join app.ph_money_journal x
 on (x.organization_id,x.user_id,x.pay_month,x.revision)=(s.organization_id,s.user_id,s.pay_month,s.revision)
 where s.organization_id=p_org and s.pay_date>=p_month and s.pay_date<e group by x.account_code) q;
 select coalesce(jsonb_object_agg(q.account_code,jsonb_build_object('debit',q.debit,'credit',q.credit)),'{}') into adj from (
 select x.account_code,sum(x.debit) debit,sum(x.credit) credit from app.ph_annual_settlement a join app.ph_annual_journal x using(organization_id,user_id,tax_year)
 join app.ph_money_active s on (a.organization_id,a.user_id,a.final_period,a.final_revision)=(s.organization_id,s.user_id,s.pay_month,s.revision)
 where a.organization_id=p_org and s.pay_date>=p_month and s.pay_date<e group by x.account_code) q;
 return jsonb_build_object('internalOnly',true,'coverageComplete',false,'month',p_month,'periodCount',n,'gross',g,'employeeContrib',ee,'employerContrib',er,'withholding',w,'net',net,'employerCost',g+er,'sources',sources,'accountNetCredits',j,'annualAdjustments',adj,'remittanceAuthorized',false);
end $$;
revoke all on function app.ph_month_liability_review(uuid,date) from public,anon,authenticated,service_role;
