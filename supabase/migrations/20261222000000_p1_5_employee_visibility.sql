-- Private, explicit per-revision publication gate; never publish ordinary accrual
-- merely because a manager can review it. No production seed or public writer.
create table app.ph_employee_payroll_release (
 organization_id uuid not null,period_start date not null,user_id uuid not null,revision int not null,
 prepared_by uuid not null references auth.users(id),reviewed_by uuid not null references auth.users(id),
 evidence_reference text not null check(length(btrim(evidence_reference))>=8),released_at timestamptz not null default clock_timestamp(),
 primary key(organization_id,period_start,user_id,revision),
 foreign key(organization_id,period_start,user_id,revision) references app.ph_monetary_snapshot,
 check(prepared_by<>reviewed_by and prepared_by<>user_id and reviewed_by<>user_id)
);
alter table app.ph_employee_payroll_release enable row level security;
revoke all on app.ph_employee_payroll_release from public,anon,authenticated,service_role;
create trigger p15_self_release_immutable before update or delete on app.ph_employee_payroll_release for each row execute function app.forbid_mutation();
create trigger p15_self_release_barrier before insert on app.ph_employee_payroll_release for each row execute function app.accounting_write_barrier();

-- No caller-selected employee or department. The only employee identity is
-- auth.uid(). No employer contribution, cost, journal, evidence or other user.
create function public.payroll_self_snapshot(p_organization_id uuid,p_period_start date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid();s app.ph_monetary_snapshot;x jsonb;ss numeric;ph numeric;pi numeric;
begin
 if u is null or p_organization_id is null or p_period_start is null then raise exception 'review unavailable' using errcode='42501';end if;
 perform app.accounting_tenant_lock(p_organization_id);
 if not app.is_member(p_organization_id) or not exists(select 1 from app.accounting_review_access a where a.organization_id=p_organization_id and a.expires_at>clock_timestamp())
 then raise exception 'review unavailable' using errcode='42501';end if;
 select m.* into s from app.ph_effective_monetary m join app.ph_employee_payroll_release r using(organization_id,period_start,user_id,revision)
 where m.organization_id=p_organization_id and m.period_start=p_period_start and m.user_id=u;
 if not found then raise exception 'personal payroll unavailable' using errcode='P0001';end if;
 x:=s.evidence->'contributions';
 ss:=coalesce((x->'sss'->>'employee')::numeric,0);ph:=coalesce((x->'philhealth'->>'employee')::numeric,0);pi:=coalesce((x->'pagibig'->>'employee')::numeric,0);
 if extract(year from s.pay_date)<>2026 or ss+ph+pi<>s.employee_contributions or s.gross-s.employee_contributions-s.withholding<>s.net then raise exception 'personal payroll unavailable' using errcode='P0001';end if;
 return jsonb_build_object('organizationId',p_organization_id,'userId',u,'periodStart',s.period_start,'periodEnd',s.pay_date,'revision',s.revision,
 'source','released-personal-accrual-v1','grossCents',(s.gross*100)::numeric(30,0)::text,
 'employeeContributionCents',(s.employee_contributions*100)::numeric(30,0)::text,
 'sssEmployeeCents',(ss*100)::numeric(30,0)::text,'philhealthEmployeeCents',(ph*100)::numeric(30,0)::text,'pagibigEmployeeCents',(pi*100)::numeric(30,0)::text,
 'withholdingCents',(s.withholding*100)::numeric(30,0)::text,'netCents',(s.net*100)::numeric(30,0)::text);
end $$;
revoke all on function public.payroll_self_snapshot(uuid,date) from public,anon,authenticated,service_role;
grant execute on function public.payroll_self_snapshot(uuid,date) to authenticated;
