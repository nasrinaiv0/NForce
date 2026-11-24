
-- Private, narrow monetary acceptance candidate; no payment, export or public RPC.
-- 2025 ordinary taxable attendance-only weekly payroll. Unsupported cases fail closed.
create table app.ph_salary_divisor_evidence (
 organization_id uuid not null,user_id uuid not null,effective_on date not null,recorded_at timestamptz not null,
 annual_paid_days numeric not null check(annual_paid_days between 1 and 366 and annual_paid_days=round(annual_paid_days,2)),
 source_reference text not null check(length(btrim(source_reference)) between 8 and 300),
 prepared_by uuid not null references auth.users(id),reviewed_by uuid not null references auth.users(id),
 primary key(organization_id,user_id,effective_on,recorded_at),
 foreign key(organization_id,user_id,effective_on,recorded_at) references app.ph_employment_history,
 check(prepared_by<>reviewed_by and prepared_by<>user_id and reviewed_by<>user_id)
);
-- Separate opening evidence: count relates to the same weekly frequency.
-- No previous employer or external current-employer YTD allowed in the
-- monetary candidate until complete document and period reconciliation.
create table app.ph_monetary_opening (
 organization_id uuid not null,user_id uuid not null,tax_year int not null check(tax_year=2025),
 first_period date not null check(extract(isodow from first_period)=1 and extract(year from first_period)=tax_year),
 evidence text not null check(length(btrim(evidence)) between 8 and 300),
 prepared_by uuid not null references auth.users(id),reviewed_by uuid not null references auth.users(id),
 primary key(organization_id,user_id,tax_year),
 foreign key(organization_id,user_id) references public.memberships(organization_id,user_id),
 check(prepared_by<>reviewed_by and prepared_by<>user_id and reviewed_by<>user_id)
);
-- Reviewed final monthly agency bases, independently classified, not gross
-- substituted for all three. One closing allocation per month; no opening
-- contribution balances permitted for this limited acceptance path.
create table app.ph_monthly_basis_evidence (
 organization_id uuid not null,user_id uuid not null,month_start date not null check(extract(day from month_start)=1),
 sss_basis numeric not null check(sss_basis>0 and sss_basis<=1000000000 and sss_basis=round(sss_basis,2)),
 philhealth_basis numeric not null check(philhealth_basis>0 and philhealth_basis<=1000000000 and philhealth_basis=round(philhealth_basis,2)),
 pagibig_basis numeric not null check(pagibig_basis>0 and pagibig_basis<=1000000000 and pagibig_basis=round(pagibig_basis,2)),
 allocation_period date not null check(extract(isodow from allocation_period)=1 and date_trunc('month',(allocation_period+6)::timestamp)::date=month_start),
 evidence text not null check(length(btrim(evidence)) between 8 and 300),
 prepared_by uuid not null references auth.users(id),reviewed_by uuid not null references auth.users(id),
 primary key(organization_id,user_id,month_start),
 foreign key(organization_id,user_id) references public.memberships(organization_id,user_id),
 check(prepared_by<>reviewed_by and prepared_by<>user_id and reviewed_by<>user_id)
);
-- Original document custody receipt: encrypted bytes are opaque to the DB.
-- A trusted external encryptor must verify plaintext SHA-256 against import,
-- manage keys, malware-scan, authenticate issuer, and attest the envelope.
-- No key or plaintext accepted; no public upload/download/decryption route.
create table app.ph_2316_custody (
 import_id uuid primary key references app.ph_2316_import(id),
 organization_id uuid not null,user_id uuid not null,
 plaintext_sha256 text not null check(plaintext_sha256 ~ '^[a-f0-9]{64}$'),
 ciphertext bytea not null check(octet_length(ciphertext) between 32 and 10485760),
 ciphertext_sha256 text not null check(ciphertext_sha256 ~ '^[a-f0-9]{64}$'),
 key_reference text not null check(length(btrim(key_reference)) between 8 and 250),
 envelope_reference text not null check(length(btrim(envelope_reference)) between 8 and 250),
 recorded_by uuid not null references auth.users(id),recorded_at timestamptz not null default now(),
 foreign key(organization_id,user_id) references public.memberships(organization_id,user_id),
 check(ciphertext_sha256=encode(sha256(ciphertext),'hex'))
);
create table app.ph_2316_custody_review (
 import_id uuid primary key references app.ph_2316_custody,
 reviewed_by uuid not null references auth.users(id),
 evidence text not null check(length(btrim(evidence)) between 8 and 300),reviewed_at timestamptz not null default now()
);
create table app.ph_monetary_snapshot (
 organization_id uuid not null,period_start date not null,user_id uuid not null,
 pay_date date not null check(pay_date=period_start+6),
 gross numeric(18,2) not null check(gross>=0),
 employee_contributions numeric(18,2) not null check(employee_contributions>=0),
 employer_contributions numeric(18,2) not null check(employer_contributions>=0),
 taxable numeric(18,2) not null check(taxable>=0),
 withholding numeric(18,2) not null check(withholding>=0),
 net numeric(18,2) not null check(net>=0),
 evidence jsonb not null,
 posted_by uuid not null references auth.users(id),posted_at timestamptz not null default now(),
 primary key(organization_id,period_start,user_id),
 foreign key(organization_id,period_start,user_id) references app.accounting_locked_snapshot,
 check(gross=taxable+employee_contributions and net=taxable-withholding)
);
-- Single immutable balanced journal entry per monetary snapshot. Lines are
-- a deterministic projection of the monetary record, not caller input.
create table app.ph_payroll_journal (
 organization_id uuid not null,period_start date not null,user_id uuid not null,
 lines jsonb not null check(jsonb_typeof(lines)='array'),
 debit_total numeric(18,2) not null,credit_total numeric(18,2) not null,
 primary key(organization_id,period_start,user_id),
 foreign key(organization_id,period_start,user_id) references app.ph_monetary_snapshot,
 check(debit_total=credit_total and debit_total>=0)
);
do $$ declare n text; begin
 foreach n in array array['ph_salary_divisor_evidence','ph_monetary_opening','ph_monthly_basis_evidence','ph_2316_custody','ph_2316_custody_review','ph_monetary_snapshot','ph_payroll_journal'] loop
 execute format('alter table app.%I enable row level security',n);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger p07_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
 end loop;
 foreach n in array array['ph_salary_divisor_evidence','ph_monetary_opening','ph_monthly_basis_evidence','ph_2316_custody','ph_monetary_snapshot','ph_payroll_journal'] loop
 execute format('create trigger a_p07_tenant_barrier before insert on app.%I for each row execute function app.accounting_write_barrier()',n);
 end loop;
end $$;
-- Attestation tables are migration-owner-only. Their actor fields alone do not
-- prove independent authentication; production importer/workflow is a gate.
create function app.ph_cumulative_withholding(p_taxable numeric,p_period_count int,p_already numeric,p_frequency text,p_date date)
returns jsonb language plpgsql immutable set search_path='' as $$
declare avg_tax numeric; total numeric;
begin
 if p_taxable is null or p_already is null or p_period_count is null or p_period_count not between 1 and 366
 or p_taxable<0 or p_taxable>1000000000 or p_taxable<>round(p_taxable,2)
 or p_already<0 or p_already>1000000000 or p_already<>round(p_already,2)
 or p_frequency not in ('weekly','semi-monthly','monthly','daily') then raise exception 'invalid cumulative evidence' using errcode='22023'; end if;
 avg_tax:=app.ph_tax_candidate(round(p_taxable/p_period_count,2),p_frequency,p_date);
 total:=avg_tax*p_period_count;
 return jsonb_build_object('cumulativeDue',total,'withhold',greatest(0,total-p_already),'excessWithheld',greatest(0,p_already-total),'periodCount',p_period_count);
end $$;
create function app.ph_store_2316_envelope(p_org uuid,p_import uuid,p_plain_hash text,p_cipher bytea,p_key text,p_ref text)
returns void language plpgsql set search_path='' as $$
declare i app.ph_2316_import;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into i from app.ph_2316_import where id=p_import and organization_id=p_org;
 if not found or auth.uid()=i.user_id then raise exception 'forbidden' using errcode='42501'; end if;
 if p_plain_hash is distinct from i.document_sha256 then raise exception 'source digest mismatch' using errcode='22023'; end if;
 insert into app.ph_2316_custody(import_id,organization_id,user_id,plaintext_sha256,ciphertext,ciphertext_sha256,key_reference,envelope_reference,recorded_by)
 values(i.id,p_org,i.user_id,p_plain_hash,p_cipher,encode(sha256(p_cipher),'hex'),p_key,p_ref,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_2316_envelope','certificate',i.id::text,'{}');
end $$;
create function app.ph_review_2316_envelope(p_org uuid,p_import uuid,p_evidence text)
returns void language plpgsql set search_path='' as $$
declare c app.ph_2316_custody;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into c from app.ph_2316_custody where import_id=p_import and organization_id=p_org;
 if not found or auth.uid() in (c.user_id,c.recorded_by) then raise exception 'independent custody review required' using errcode='42501'; end if;
 insert into app.ph_2316_custody_review(import_id,reviewed_by,evidence) values(p_import,auth.uid(),p_evidence);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_2316_custody_review','certificate',p_import::text,'{}');
end $$;
-- Private snapshot writer. Original exact seconds and historical rate are
-- authority; no caller-supplied gross, deductions, withholding or net.
create function app.ph_post_monetary_week(p_org uuid,p_period date,p_user uuid)
returns jsonb language plpgsql set search_path='' as $$
declare s app.accounting_locked_snapshot; o app.ph_monetary_opening; m app.ph_monthly_basis_evidence;
 h app.ph_employment_history; dv app.ph_salary_divisor_evidence; l jsonb;
 line_amount numeric; raw_gross numeric:=0; gross numeric; hourly numeric;
 ee numeric:=0; er numeric:=0; tax numeric; net numeric; taxable numeric;
 prev_taxable numeric; prev_tax numeric; n int; last_period date; pd date:=p_period+6; mon date;
 contrib jsonb:='{}'; j jsonb; agency text; basis numeric; v jsonb; lines jsonb:='[]'; journal jsonb; total numeric;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') or not app.has_permission(p_org,'timesheet.lock') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_period is null or extract(isodow from p_period)<>1 or extract(year from pd)<>2025 or extract(year from p_period)<>2025 then raise exception 'unsupported monetary period' using errcode='22023'; end if;
 if exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and period_start=p_period and user_id=p_user) then raise exception 'monetary snapshot already posted' using errcode='P0001'; end if;
 select * into s from app.accounting_locked_snapshot where organization_id=p_org and period_start=p_period and user_id=p_user;
 if not found or s.reconciliation->>'classificationVersion' is distinct from '4' or (s.reconciliation->>'exactOvertimeReviewSeconds')::numeric<>0 then raise exception 'locked exact reconciled PH attendance required' using errcode='P0001'; end if;
 if exists(select 1 from app.accounting_adjustment_proposal where organization_id=p_org and period_start=p_period and user_id=p_user) then raise exception 'adjusted payroll requires settlement review' using errcode='P0001'; end if;
 select * into o from app.ph_monetary_opening where organization_id=p_org and user_id=p_user and tax_year=2025;
 if not found then raise exception 'reviewed zero opening and coverage required' using errcode='P0001'; end if;
 if exists(select 1 from app.ph_2316_import where organization_id=p_org and user_id=p_user and tax_year=2025) then raise exception 'prior employer monetary integration not enabled' using errcode='P0001'; end if;
 select count(*)::int,coalesce(sum(x.taxable),0),coalesce(sum(x.withholding),0),max(x.period_start)
 into n,prev_taxable,prev_tax,last_period from app.ph_monetary_snapshot x where organization_id=p_org and user_id=p_user and extract(year from x.pay_date)=2025;
 if (n=0 and p_period<>o.first_period) or (n>0 and p_period<>last_period+7) then raise exception 'noncontiguous payroll history' using errcode='P0001'; end if;
 for l in select value from jsonb_array_elements(s.reconciliation->'payLines') loop
 select eh.* into h from app.ph_workday_evidence e join app.ph_employment_history eh on (eh.organization_id,eh.user_id,eh.effective_on,eh.recorded_at)=(e.organization_id,e.user_id,e.employment_effective_on,e.employment_recorded_at)
 where e.organization_id=p_org and e.period_start=p_period and e.user_id=p_user and e.work_date=(l->>'workday')::date;
 if not found or h.status<>'employed' then raise exception 'historical pay evidence missing' using errcode='P0001'; end if;
 if h.pay_basis='hourly' then hourly:=h.rate_php;
 elsif h.pay_basis='daily' then hourly:=h.rate_php/8;
 elsif h.pay_basis='monthly' then
 select * into dv from app.ph_salary_divisor_evidence where (organization_id,user_id,effective_on,recorded_at)=(h.organization_id,h.user_id,h.effective_on,h.recorded_at);
 if not found then raise exception 'reviewed salary divisor missing' using errcode='P0001'; end if;
 hourly:=h.rate_php*12/dv.annual_paid_days/8;
 else raise exception 'unsupported basis' using errcode='22023'; end if;
 line_amount:=hourly*(l->>'seconds')::numeric/3600*(l->>'multiplier')::numeric;
 raw_gross:=raw_gross+line_amount;
 lines:=lines||jsonb_build_array(l||jsonb_build_object('hourlyRate',hourly,'unroundedAmount',line_amount,'employmentRevision',h.recorded_at));
 end loop;
 gross:=round(raw_gross,2);
 mon:=date_trunc('month',pd::timestamp)::date;
 select * into m from app.ph_monthly_basis_evidence where organization_id=p_org and user_id=p_user and month_start=mon;
 if not found then raise exception 'reviewed monthly agency bases missing' using errcode='P0001'; end if;
 if p_period>m.allocation_period and not exists(select 1 from app.ph_monetary_snapshot where organization_id=p_org and user_id=p_user and period_start=m.allocation_period) then raise exception 'missing monthly allocation' using errcode='P0001'; end if;
 if p_period=m.allocation_period then
 foreach agency in array array['sss','philhealth','pagibig'] loop
 basis:=case agency when 'sss' then m.sss_basis when 'philhealth' then m.philhealth_basis else m.pagibig_basis end;
 v:=app.ph_contribution_candidate(agency,basis,mon);
 ee:=ee+(v->>'employee')::numeric;er:=er+(v->>'employer')::numeric;
 contrib:=contrib||jsonb_build_object(agency,v);
 end loop;
 end if;
 if gross<ee then raise exception 'insufficient compensation for contribution allocation' using errcode='P0001'; end if;
 taxable:=gross-ee;
 j:=app.ph_cumulative_withholding(prev_taxable+taxable,n+1,prev_tax,'weekly',pd);
 tax:=(j->>'withhold')::numeric;
 if tax>taxable then raise exception 'insufficient compensation for withholding' using errcode='P0001'; end if;
 net:=taxable-tax;
 total:=gross+er;
 journal:=jsonb_build_array(jsonb_build_object('account','wage_expense','debit',gross,'credit',0),
 jsonb_build_object('account','employer_contribution_expense','debit',er,'credit',0),
 jsonb_build_object('account','employee_contribution_payable','debit',0,'credit',ee),
 jsonb_build_object('account','employer_contribution_payable','debit',0,'credit',er),
 jsonb_build_object('account','withholding_payable','debit',0,'credit',tax),
 jsonb_build_object('account','net_payable','debit',0,'credit',net));
 if (select sum((x->>'debit')::numeric) from jsonb_array_elements(journal)x)<>total
 or (select sum((x->>'credit')::numeric) from jsonb_array_elements(journal)x)<>total then raise exception 'unbalanced payroll' using errcode='P0001'; end if;
 v:=jsonb_build_object('earnings',lines,'contributions',contrib,'cumulative',j,'openingEvidence',o.evidence,'basisEvidence',m.evidence,'method','ph-weekly-2025-attendance-candidate');
 insert into app.ph_monetary_snapshot(organization_id,period_start,user_id,pay_date,gross,employee_contributions,employer_contributions,taxable,withholding,net,evidence,posted_by)
 values(p_org,p_period,p_user,pd,gross,ee,er,taxable,tax,net,v,auth.uid());
 insert into app.ph_payroll_journal values(p_org,p_period,p_user,journal,total,total);
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data)
 values(p_org,auth.uid(),'accounting.ph_monetary_snapshot','membership',p_user::text,jsonb_build_object('periodStart',p_period));
 return jsonb_build_object('gross',gross,'employeeContributions',ee,'employerContributions',er,'taxable',taxable,'withholding',tax,'net',net,'journalTotal',total);
end $$;
revoke all on function app.ph_cumulative_withholding(numeric,int,numeric,text,date),
 app.ph_store_2316_envelope(uuid,uuid,text,bytea,text,text),app.ph_review_2316_envelope(uuid,uuid,text),
 app.ph_post_monetary_week(uuid,date,uuid) from public,anon,authenticated,service_role;
