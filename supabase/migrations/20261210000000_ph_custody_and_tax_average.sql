-- Private staging custody: encrypted envelope only; a trusted external encryptor
-- must authenticate the source PDF, bind its plaintext hash and manage keys.
create table app.ph_2316_custody (
 organization_id uuid not null, import_id uuid primary key references app.ph_2316_import(id),
 ciphertext bytea not null check(octet_length(ciphertext) between 32 and 10485760),
 ciphertext_sha256 text not null check(ciphertext_sha256=encode(sha256(ciphertext),'hex')),
 plaintext_sha256 text not null check(plaintext_sha256 ~ '^[a-f0-9]{64}$'),
 key_reference text not null check(length(btrim(key_reference)) between 8 and 200),
 envelope_version text not null check(envelope_version='AES-256-GCM-v1'),
 evidence_reference text not null check(length(btrim(evidence_reference)) between 1 and 300),
 deposited_by uuid not null references auth.users(id),deposited_at timestamptz not null default clock_timestamp()
);
create table app.ph_2316_custody_review (
 import_id uuid primary key references app.ph_2316_custody, organization_id uuid not null,
 verification_reference text not null check(length(btrim(verification_reference)) between 1 and 300),
 verified_by uuid not null references auth.users(id),verified_at timestamptz not null default clock_timestamp()
);
do $$ declare n text; begin
 foreach n in array array['ph_2316_custody','ph_2316_custody_review'] loop
 execute format('alter table app.%I enable row level security',n);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger ph_custody_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
 execute format('create trigger a_ph_custody_tenant before insert or update or delete on app.%I for each row execute function app.accounting_write_barrier()',n);
 end loop;
end $$;
create function app.ph_deposit_2316(p_org uuid,p_import uuid,p_cipher bytea,p_cipher_hash text,p_plain_hash text,p_key text,p_reference text)
returns void language plpgsql set search_path='' as $$
declare i app.ph_2316_import; old app.ph_2316_custody;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into i from app.ph_2316_import where organization_id=p_org and id=p_import;
 if not found or auth.uid()=i.user_id then raise exception 'forbidden' using errcode='42501'; end if;
 if p_cipher is null or p_cipher_hash is distinct from encode(sha256(p_cipher),'hex') or p_plain_hash is distinct from i.document_sha256
 then raise exception 'custody hash mismatch' using errcode='22023'; end if;
 select * into old from app.ph_2316_custody where import_id=p_import and organization_id=p_org;
 if found then
 if (old.ciphertext_sha256,old.plaintext_sha256,old.key_reference,old.evidence_reference) is distinct from (p_cipher_hash,p_plain_hash,p_key,p_reference)
 then raise exception 'custody conflict' using errcode='22023'; end if;
 return; end if;
 insert into app.ph_2316_custody(organization_id,import_id,ciphertext,ciphertext_sha256,plaintext_sha256,key_reference,envelope_version,evidence_reference,deposited_by)
 values(p_org,p_import,p_cipher,p_cipher_hash,p_plain_hash,p_key,'AES-256-GCM-v1',p_reference,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.2316_custody_deposited','certificate',p_import::text,'{}');
end $$;
create function app.ph_verify_2316_custody(p_org uuid,p_import uuid,p_reference text)
returns void language plpgsql set search_path='' as $$
declare c app.ph_2316_custody;i app.ph_2316_import;
begin
 perform app.accounting_tenant_lock(p_org);
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into c from app.ph_2316_custody where organization_id=p_org and import_id=p_import;
 select * into i from app.ph_2316_import where organization_id=p_org and id=p_import;
 if c.import_id is null or i.id is null or auth.uid() in(c.deposited_by,i.imported_by,i.user_id)
 then raise exception 'independent custody verification required' using errcode='42501'; end if;
 if not exists(select 1 from app.ph_2316_review r where r.import_id=p_import and r.approved) then raise exception 'approved certificate required' using errcode='P0001'; end if;
 insert into app.ph_2316_custody_review(import_id,organization_id,verification_reference,verified_by) values(p_import,p_org,p_reference,auth.uid());
 insert into public.audit_events(organization_id,actor_id,action,entity,entity_id,data) values(p_org,auth.uid(),'accounting.2316_custody_verified','certificate',p_import::text,'{}');
end $$;
-- Periodic BIR cumulative average, not annual tax divided by 12.
create function app.ph_cumulative_tax(p_total numeric,p_periods integer,p_prior_withheld numeric,p_frequency text,p_day date)
returns jsonb language plpgsql immutable set search_path='' as $$
declare avg_pay numeric; avg_tax numeric; cumulative numeric;
begin
 if p_total is null or p_total::text in ('NaN','Infinity','-Infinity') or p_total<0 or p_total>1000000000 or p_total<>round(p_total,2)
 or p_prior_withheld is null or p_prior_withheld::text in ('NaN','Infinity','-Infinity') or p_prior_withheld<0 or p_prior_withheld>1000000000 or p_prior_withheld<>round(p_prior_withheld,2)
 or p_periods is null or p_frequency is null or p_frequency not in ('monthly','semi-monthly','weekly','daily')
 or p_periods<1 or p_periods>case p_frequency when 'monthly' then 12 when 'semi-monthly' then 24 when 'weekly' then 53 else 366 end
 then raise exception 'invalid cumulative withholding inputs' using errcode='22023'; end if;
 avg_pay:=round(p_total/p_periods,2);
 avg_tax:=app.ph_tax_candidate(avg_pay,p_frequency,p_day);
 cumulative:=avg_tax*p_periods;
 return jsonb_build_object('averagePay',avg_pay,'averageTax',avg_tax,'cumulativeTax',cumulative,
 'withholding',greatest(0,cumulative-p_prior_withheld),'overwithheldToReview',greatest(0,p_prior_withheld-cumulative));
end $$;
-- No universal divisor; only genuinely monthly paid, full salary including all calendar days.
create function app.ph_monthly_hourly(p_salary numeric,p_divisor numeric,p_year integer)
returns numeric language plpgsql immutable set search_path='' as $$
begin
 if p_salary is null or p_salary::text in ('NaN','Infinity','-Infinity') or p_salary<=0 or p_salary>1000000000 or p_salary<>round(p_salary,2)
 or p_year is null or p_year not between 2023 and 2026 or p_divisor is distinct from (make_date(p_year+1,1,1)-make_date(p_year,1,1))::numeric
 then raise exception 'unsupported monthly-paid divisor' using errcode='22023'; end if;
 return p_salary*12/p_divisor/8;
end $$;
revoke all on function app.ph_deposit_2316(uuid,uuid,bytea,text,text,text,text),app.ph_verify_2316_custody(uuid,uuid,text),
app.ph_cumulative_tax(numeric,integer,numeric,text,date),app.ph_monthly_hourly(numeric,numeric,integer)
from public,anon,authenticated,service_role;
