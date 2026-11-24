-- One shared canonical evidence model. No API grants, production seeds or new custody.
create table app.ph_payroll_attestation (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,user_id uuid not null,
 kind text not null check(kind in ('opening','period','wage','contribution','annual','replay')),
 scope_date date not null check(scope_date between date '2026-01-01' and date '2026-11-24'),
 payload jsonb not null check(jsonb_typeof(payload)='object' and octet_length(payload::text)<=32000),
 evidence text not null check(length(btrim(evidence)) between 8 and 300),
 maker uuid not null references auth.users(id),made_at timestamptz not null default clock_timestamp(),
 foreign key(organization_id,user_id) references public.memberships(organization_id,user_id),
 unique(organization_id,user_id,kind,scope_date),check(maker<>user_id)
);
create table app.ph_payroll_attestation_decision (
 attestation_id uuid primary key references app.ph_payroll_attestation,
 organization_id uuid not null references public.organizations(id),
 checker uuid not null references auth.users(id),
 evidence text not null check(length(btrim(evidence)) between 8 and 300),
 checked_at timestamptz not null default clock_timestamp()
);
do $$ declare t text;begin
 foreach t in array array['ph_payroll_attestation','ph_payroll_attestation_decision'] loop
 execute format('alter table app.%I enable row level security',t);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',t);
 execute format('create trigger p09_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',t);
 execute format('create trigger a_p09_tenant before insert or update or delete on app.%I for each row execute function app.accounting_write_barrier()',t);
 end loop;
end $$;
create function app.ph_prepare_payroll_evidence(p_org uuid,p_user uuid,p_kind text,p_date date,p_payload jsonb,p_evidence text)
returns uuid language plpgsql set search_path='' as $$
declare a app.ph_payroll_attestation;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501';end if;
 select * into a from app.ph_payroll_attestation where organization_id=p_org and user_id=p_user and kind=p_kind and scope_date=p_date;
 if found then
 if (a.payload,a.evidence,a.maker) is distinct from (p_payload,p_evidence,auth.uid()) then raise exception 'attestation conflict' using errcode='22023';end if;
 return a.id;
 end if;
 insert into app.ph_payroll_attestation(organization_id,user_id,kind,scope_date,payload,evidence,maker)
 values(p_org,p_user,p_kind,p_date,p_payload,p_evidence,auth.uid()) returning * into a;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_evidence_prepared','attestation',a.id::text,jsonb_build_object('kind',p_kind));
 return a.id;
end $$;
create function app.ph_approve_payroll_evidence(p_org uuid,p_id uuid,p_ref text)
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
 when 'annual' then
 if y->>'reason' is null or y->>'reason' not in ('termination','year_end')
 or not app.ph_stat_money((y->>'available')::numeric) or y->>'completeFinalCompensation' is distinct from 'true'
 then raise exception 'complete reviewed settlement required' using errcode='22023';end if;
 end case;
 insert into app.ph_payroll_attestation_decision(attestation_id,organization_id,checker,evidence) values(a.id,p_org,auth.uid(),p_ref);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_evidence_approved','attestation',a.id::text,jsonb_build_object('kind',a.kind));
end $$;
create function app.ph_approved_evidence(p_org uuid,p_user uuid,p_kind text,p_date date)
returns app.ph_payroll_attestation language plpgsql stable set search_path='' as $$
declare a app.ph_payroll_attestation;
begin
 select x.* into a from app.ph_payroll_attestation x join app.ph_payroll_attestation_decision d on d.attestation_id=x.id and d.organization_id=x.organization_id
 where x.organization_id=p_org and x.user_id=p_user and x.kind=p_kind and x.scope_date=p_date and d.checker<>x.maker and d.checker<>x.user_id;
 if not found then raise exception 'approved evidence missing: %',p_kind using errcode='P0001';end if;return a;
end $$;
create function app.ph_wage_on(p_org uuid,p_user uuid,p_day date,p_site text,p_order text)
returns app.ph_payroll_attestation language plpgsql stable set search_path='' as $$
declare a app.ph_payroll_attestation;
begin
 -- Do not silently reuse an earlier order after a new effective wage row.
 select x.* into a from app.ph_payroll_attestation x join app.ph_payroll_attestation_decision d on d.attestation_id=x.id and d.organization_id=x.organization_id
 where x.organization_id=p_org and x.user_id=p_user and x.kind='wage' and x.scope_date<=p_day and d.checker<>x.maker and d.checker<>x.user_id
 order by x.scope_date desc limit 1;
 if not found or (a.payload->>'through')::date<p_day or a.payload->>'site' is distinct from p_site or a.payload->>'order' is distinct from p_order
 then raise exception 'matching current wage order/category evidence missing' using errcode='P0001';end if;return a;
end $$;
-- Port PR17 reviewed retrieval using the existing canonical encrypted custody.
create function app.ph_get_reviewed_envelope(p_org uuid,p_import uuid)
returns jsonb language plpgsql set search_path='' as $$
declare c app.ph_2316_custody;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501';end if;
 select x.* into c from app.ph_2316_custody x join app.ph_2316_custody_review cr on cr.import_id=x.import_id and cr.organization_id=x.organization_id
 join app.ph_2316_import i on i.id=x.import_id and i.organization_id=x.organization_id
 join app.ph_2316_review r on r.import_id=i.id and r.approved
 where x.organization_id=p_org and x.import_id=p_import and i.user_id<>auth.uid();
 if not found then raise exception 'reviewed envelope unavailable' using errcode='42501';end if;
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_envelope_retrieved','certificate',p_import::text,'{}');
 return jsonb_build_object('ciphertext',encode(c.ciphertext,'base64'),'sha256',c.ciphertext_sha256,'plaintextSha256',c.plaintext_sha256,'keyReference',c.key_reference);
end $$;
revoke all on function app.ph_prepare_payroll_evidence(uuid,uuid,text,date,jsonb,text),app.ph_approve_payroll_evidence(uuid,uuid,text),
app.ph_approved_evidence(uuid,uuid,text,date),app.ph_wage_on(uuid,uuid,date,text,text),app.ph_get_reviewed_envelope(uuid,uuid)
from public,anon,authenticated,service_role;
