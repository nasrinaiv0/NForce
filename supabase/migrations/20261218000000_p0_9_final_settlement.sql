-- Tax settlement is a distinct balanced adjustment, not a second payroll
-- calculation engine. Only complete reviewed and undispatched final accruals.
create table app.ph_annual_settlement (
 organization_id uuid not null,user_id uuid not null,tax_year int not null check(tax_year=2026),
 final_period date not null,final_revision int not null,
 attestation_id uuid not null references app.ph_payroll_attestation(id),
 result jsonb not null,recorded_by uuid not null references auth.users(id),recorded_at timestamptz not null default clock_timestamp(),
 primary key(organization_id,user_id,tax_year),
 foreign key(organization_id,user_id,final_period,final_revision) references app.ph_money_snapshot
);
create table app.ph_annual_journal (
 organization_id uuid not null,user_id uuid not null,tax_year int not null,
 account_code text not null,debit numeric not null,credit numeric not null,
 primary key(organization_id,user_id,tax_year,account_code),
 foreign key(organization_id,user_id,tax_year) references app.ph_annual_settlement,
 check(debit>=0 and credit>=0 and debit=round(debit,2) and credit=round(credit,2) and (debit=0 or credit=0))
);
do $$ declare t text;begin
 foreach t in array array['ph_annual_settlement','ph_annual_journal'] loop
 execute format('alter table app.%I enable row level security',t);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',t);
 execute format('create trigger p09_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',t);
 execute format('create trigger a_p09_tenant before insert or update or delete on app.%I for each row execute function app.accounting_write_barrier()',t);
 end loop;
end $$;
-- 13th reconciliation against the effective payroll and immutable paid benefit
-- ledger, not against caller-supplied annual basic totals.
create function app.ph_thirteenth_reconcile_2026(p_org uuid,p_user uuid,p_through date)
returns jsonb language plpgsql stable set search_path='' as $$
declare basic numeric; paid numeric; a app.ph_payroll_attestation; start_date date;
begin
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501';end if;
 a:=app.ph_approved_evidence(p_org,p_user,'annual',p_through);
 start_date:=(app.ph_approved_evidence(p_org,p_user,'opening','2026-01-01')).payload->>'firstPeriod';
 if a.payload->>'rankAndFileEligible' is distinct from 'true' or p_through+1<(start_date+interval '1 month')::date
 or not app.ph_stat_money((a.payload->>'maternityDifferential')::numeric)
 or not app.ph_stat_money((a.payload->>'integratedBasic')::numeric)
 then raise exception 'reviewed 13th-month eligibility and components required' using errcode='P0001';end if;
 select coalesce(sum((s.calculation->>'basic')::numeric),0) into basic from app.ph_money_active s
 where s.organization_id=p_org and s.user_id=p_user and s.pay_date between start_date and p_through;
 select coalesce(sum((e.result->>'gross')::numeric),0) into paid from app.ph_benefit_event e
 where e.organization_id=p_org and e.user_id=p_user and e.tax_year=2026 and e.paid_on between start_date and p_through
 and e.request->>'code'='13th_month'
 and exists(select 1 from app.ph_money_active s where s.organization_id=p_org and s.user_id=p_user
 and e.paid_on between s.pay_month and s.period_end and s.calculation->'benefitKeys' ? e.event_key);
 return app.ph_thirteenth_amount(basic,(a.payload->>'maternityDifferential')::numeric,(a.payload->>'integratedBasic')::numeric,paid,true,a.evidence);
end $$;
create function app.ph_record_annual_settlement_2026(p_org uuid,p_user uuid,p_final_period date)
returns jsonb language plpgsql set search_path='' as $$
declare s app.ph_money_snapshot; a app.ph_payroll_attestation;old app.ph_annual_settlement; h app.ph_employment_history;
 prior jsonb; t numeric;w numeric; avail numeric;j jsonb;b jsonb; take numeric;advance numeric;refund numeric;bal numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501';end if;
 select * into old from app.ph_annual_settlement where organization_id=p_org and user_id=p_user and tax_year=2026;
 if found then
 if old.final_period is distinct from p_final_period then raise exception 'settlement already recorded' using errcode='P0001';end if;return old.result;end if;
 select * into s from app.ph_money_active where organization_id=p_org and user_id=p_user and pay_month=p_final_period and extract(year from pay_month)=2026;
 if not found or exists(select 1 from app.ph_money_snapshot x where x.organization_id=p_org and x.user_id=p_user and extract(year from x.pay_month)=2026 and x.pay_month>p_final_period)
 or exists(select 1 from app.ph_money_reversal r where r.organization_id=p_org and r.user_id=p_user and extract(year from r.pay_month)=2026
 and not exists(select 1 from app.ph_money_snapshot z where (z.organization_id,z.user_id,z.pay_month,z.revision)=(r.organization_id,r.user_id,r.pay_month,2)))
 then raise exception 'complete active final payroll required' using errcode='P0001';end if;
 a:=app.ph_approved_evidence(p_org,p_user,'annual',s.pay_date);
 if a.maker=auth.uid() or a.payload->>'undispatched' is distinct from 'true'
 or a.payload->>'completeExitEntitlements' is distinct from 'true'
 then raise exception 'independent final settlement and undispatched accrual review required' using errcode='42501';end if;
 -- Year-end 2026 is future at the current verified cutoff. This route only
 -- accepts a completed ordinary resignation with no outstanding separation,
 -- retirement, maternity, or other special settlement amounts.
 if a.payload->>'reason'<>'termination' or a.payload->>'exitKind' is distinct from 'ordinary_resignation_no_severance'
 or (a.payload->>'maternityDifferential')::numeric is distinct from 0::numeric
 or (a.payload->>'integratedBasic')::numeric is distinct from 0::numeric
 then raise exception 'unsupported final settlement scope' using errcode='P0001';end if;
 h:=app.ph_employment_as_of(p_org,p_user,s.period_end+1,clock_timestamp());
 if h.status<>'separated' then raise exception 'reviewed separation effective immediately after final period required' using errcode='P0001';end if;
 b:=app.ph_thirteenth_reconcile_2026(p_org,p_user,s.pay_date);
 if (b->>'remaining')::numeric<>0 then raise exception 'unreconciled 13th-month pay' using errcode='P0001';end if;
 if exists(select 1 from app.ph_benefit_event e where e.organization_id=p_org and e.user_id=p_user and e.tax_year=2026 and e.paid_on>s.pay_date)
 then raise exception 'later benefit requires settlement review' using errcode='P0001';end if;
 avail:=(a.payload->>'available')::numeric;
 if avail>s.net then raise exception 'available compensation exceeds final accrual' using errcode='P0001';end if;
 prior:=app.ph_prior_employer_2026(p_org,p_user);
 select coalesce(sum(taxable),0),coalesce(sum(withholding),0) into t,w from app.ph_money_active
 where organization_id=p_org and user_id=p_user and extract(year from pay_month)=2026;
 j:=app.ph_annual_adjustment(s.pay_date,s.pay_date,'termination',t,(prior->>'taxable')::numeric,w,(prior->>'withheld')::numeric,avail,a.evidence)
 ||jsonb_build_object('finalRevision',s.revision,'priorEmployer',prior,'thirteenth',b,'settlementOnly',true);
 take:=(j->>'employeeWithholding')::numeric;advance:=(j->>'employerAdvance')::numeric;refund:=(j->>'refund')::numeric;
 insert into app.ph_annual_settlement(organization_id,user_id,tax_year,final_period,final_revision,attestation_id,result,recorded_by)
 values(p_org,p_user,2026,p_final_period,s.revision,a.id,j,auth.uid());
 insert into app.ph_annual_journal select p_org,p_user,2026,v.code,v.debit,v.credit from (values
 ('salary_payable',take,refund),('employee_tax_advance_receivable',advance,0::numeric),
 ('bir_withholding_payable',refund,take+advance)
 ) v(code,debit,credit) where v.debit<>0 or v.credit<>0;
 select coalesce(sum(debit-credit),0) into bal from app.ph_annual_journal where organization_id=p_org and user_id=p_user and tax_year=2026;
 if bal<>0 then raise exception 'unbalanced annual adjustment' using errcode='P0001';end if;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_annual_settled','membership',p_user::text,jsonb_build_object('taxYear',2026,'finalPeriod',p_final_period));
 return j;
end $$;
-- Block posting/reversal changes after final settlement. Tax corrections require
-- their own reviewed amended return/reconciliation rather than silent mutation.
create function app.ph_guard_annual_closed() returns trigger language plpgsql set search_path='' as $$
begin
 perform app.accounting_tenant_lock(new.organization_id);
 if exists(select 1 from app.ph_annual_settlement a where a.organization_id=new.organization_id and a.user_id=new.user_id and a.tax_year=extract(year from new.pay_month))
 then raise exception 'tax year settled; reviewed amended settlement required' using errcode='42501';end if;return new;
end $$;
create trigger ph_annual_closed before insert on app.ph_money_snapshot for each row execute function app.ph_guard_annual_closed();
create trigger ph_annual_closed before insert on app.ph_money_reversal_proposal for each row execute function app.ph_guard_annual_closed();
create trigger ph_annual_closed before insert on app.ph_money_reversal for each row execute function app.ph_guard_annual_closed();
revoke all on function app.ph_thirteenth_reconcile_2026(uuid,uuid,date),app.ph_record_annual_settlement_2026(uuid,uuid,date),app.ph_guard_annual_closed()
from public,anon,authenticated,service_role;
