-- Private statutory ledger. Opening balances require independent review; no API grants.
create table app.ph_benefit_year (
 organization_id uuid not null, user_id uuid not null, tax_year integer not null check(tax_year=2026),
 opening_through date not null check(opening_through between date '2026-01-05' and date '2026-11-24'),
 opening_buckets jsonb not null check(jsonb_typeof(opening_buckets)='object'),
 opening_other numeric not null check(opening_other>=0 and opening_other<=1000000000 and opening_other=round(opening_other,2)),
 medical_mode text not null check(medical_mode in ('monthly','semester')),
 evidence_reference text not null check(length(btrim(evidence_reference)) between 1 and 300),
 attested_by uuid not null references auth.users(id),
 primary key(organization_id,user_id,tax_year),
 foreign key(organization_id,user_id) references public.memberships(organization_id,user_id)
);
create table app.ph_benefit_event (
 organization_id uuid not null,user_id uuid not null,tax_year integer not null,
 event_key text not null check(length(event_key) between 8 and 128),
 paid_on date not null, sequence_no bigint not null check(sequence_no>0),
 request jsonb not null,result jsonb not null, recorded_by uuid not null references auth.users(id),
 primary key(organization_id,user_id,tax_year,event_key),
 unique(organization_id,user_id,tax_year,sequence_no),
 foreign key(organization_id,user_id,tax_year) references app.ph_benefit_year
);
-- Source artifact is retained externally in an approved private vault; no raw TIN or document bytes here.
create table app.ph_2316_import (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null,user_id uuid not null,
 tax_year integer not null check(tax_year between 2023 and 2026),
 issuer_ref text not null check(length(btrim(issuer_ref)) between 8 and 128),
 document_sha256 text not null check(document_sha256 ~ '^[a-f0-9]{64}$'),
 period_from date not null,period_to date not null,
 fields jsonb not null, evidence_reference text not null check(length(btrim(evidence_reference)) between 1 and 300),
 imported_by uuid not null references auth.users(id),
 unique(organization_id,user_id,tax_year,document_sha256),
 foreign key(organization_id,user_id) references public.memberships(organization_id,user_id),
 check(isfinite(period_from) and isfinite(period_to) and period_from<=period_to
   and extract(year from period_from)=tax_year and extract(year from period_to)=tax_year)
);
create table app.ph_2316_review (
 import_id uuid primary key references app.ph_2316_import,
 approved boolean not null, review_reference text not null check(length(btrim(review_reference)) between 1 and 300),
 reviewed_by uuid not null references auth.users(id), reviewed_at timestamptz not null default clock_timestamp()
);
do $$ declare n text; begin
 foreach n in array array['ph_benefit_year','ph_benefit_event','ph_2316_import','ph_2316_review'] loop
 execute format('alter table app.%I enable row level security',n);
 execute format('revoke all on app.%I from public,anon,authenticated,service_role',n);
 execute format('create trigger ph_statutory_immutable before update or delete on app.%I for each row execute function app.forbid_mutation()',n);
 end loop;
end $$;
create function app.ph_open_benefit_year(p_org uuid,p_user uuid,p_through date,p_buckets jsonb,p_other numeric,p_mode text,p_evidence text)
returns void language plpgsql set search_path='' as $$
declare k text; v jsonb;
begin
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 if jsonb_typeof(p_buckets) is distinct from 'object' then raise exception 'opening buckets required' using errcode='22023'; end if;
 for k,v in select * from jsonb_each(p_buckets) loop
  if length(k)>100 or jsonb_typeof(v)<>'number' or v::text::numeric<0 or v::text::numeric>1000000000 or v::text::numeric<>round(v::text::numeric,2)
  then raise exception 'invalid opening balance' using errcode='22023'; end if;
 end loop;
 insert into app.ph_benefit_year values(p_org,p_user,extract(year from p_through)::integer,p_through,p_buckets,p_other,p_mode,p_evidence,auth.uid());
end $$;
create function app.ph_post_benefit(p_org uuid,p_user uuid,p_key text,p_day date,p_code text,p_amount numeric,p_units numeric,p_wage numeric,p_evidence text)
returns jsonb language plpgsql set search_path='' as $$
declare y app.ph_benefit_year; old app.ph_benefit_event; req jsonb; res jsonb; probe jsonb; bucket text;
 seq bigint; last_day date; prior numeric; other_prior numeric; yr integer;
begin
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_day is null or not isfinite(p_day) or p_key is null or length(p_key) not between 8 and 128
 or p_code is null or p_code not in ('rice','laundry','uniform','medical_assistance','achievement_award','christmas_anniversary_gift','cba','productivity','dependent_medical','ot_night_meal','vacation_conversion','13th_month','qualified_other_benefit')
 then raise exception 'invalid benefit event' using errcode='22023'; end if;
 yr:=extract(year from p_day)::integer;
 -- Row lock serializes all monthly/annual benefit buckets for this tenant employee year.
 select * into y from app.ph_benefit_year where organization_id=p_org and user_id=p_user and tax_year=yr for update;
 if not found then raise exception 'attested opening balances required' using errcode='P0001'; end if;
 req:=jsonb_build_object('date',p_day,'code',p_code,'amount',p_amount,'units',p_units,'wage',p_wage,'evidence',p_evidence);
 select * into old from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=yr and event_key=p_key;
 if found then
  if old.request is distinct from req then raise exception 'idempotency conflict' using errcode='22023'; end if;
  return old.result;
 end if;
 select coalesce(max(sequence_no),0),max(paid_on) into seq,last_day from app.ph_benefit_event where organization_id=p_org and user_id=p_user and tax_year=yr;
 if p_day<=y.opening_through or (last_day is not null and p_day<last_day) then raise exception 'backdated benefit requires reviewed replay' using errcode='22023'; end if;
 probe:=app.ph_compensation_classify(p_day,p_code,p_amount,0,0,false,p_evidence,p_units,p_wage,y.medical_mode);
 bucket:=probe->>'bucket';
 prior:=coalesce((y.opening_buckets->>bucket)::numeric,0);
 if bucket is not null then
 select coalesce((select (e.result->>'bucketUsage')::numeric from app.ph_benefit_event e
 where e.organization_id=p_org and e.user_id=p_user and e.tax_year=yr and e.result->>'bucket'=bucket order by sequence_no desc limit 1),prior) into prior;
 end if;
 select coalesce((select (e.result->>'otherBenefitUsage')::numeric from app.ph_benefit_event e
 where e.organization_id=p_org and e.user_id=p_user and e.tax_year=yr order by sequence_no desc limit 1),y.opening_other) into other_prior;
 res:=app.ph_compensation_classify(p_day,p_code,p_amount,prior,other_prior,false,p_evidence,p_units,p_wage,y.medical_mode);
 insert into app.ph_benefit_event values(p_org,p_user,yr,p_key,p_day,seq+1,req,res,auth.uid());
 return res;
end $$;

-- Source form 2316 Sept 2021 ENCS. Each document contributes its own employer's items 21 and 25A only.
create function app.ph_import_2316(p_org uuid,p_user uuid,p_year integer,p_issuer text,p_hash text,p_from date,p_to date,p_fields jsonb,p_reference text)
returns uuid language plpgsql set search_path='' as $$
declare k text; v numeric; old app.ph_2316_import; out_id uuid;
begin
 if auth.uid() is null or auth.uid()=p_user or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_fields is null or jsonb_typeof(p_fields)<>'object' then raise exception 'form fields required' using errcode='22023'; end if;
 foreach k in array array['19','20','21','22','23','24','25A','25B','26','27','28','34','38','52'] loop
  if jsonb_typeof(p_fields->k) is distinct from 'number' then raise exception 'missing form item %',k using errcode='22023'; end if;
  v:=(p_fields->>k)::numeric;
  if v<0 or v>1000000000 or v<>round(v,2) then raise exception 'invalid form item %',k using errcode='22023'; end if;
 end loop;
 if (p_fields->>'19')::numeric<>(p_fields->>'20')::numeric+(p_fields->>'21')::numeric
 or (p_fields->>'20')::numeric<>(p_fields->>'38')::numeric or (p_fields->>'21')::numeric<>(p_fields->>'52')::numeric
 or (p_fields->>'23')::numeric<>(p_fields->>'21')::numeric+(p_fields->>'22')::numeric
 or (p_fields->>'26')::numeric<>(p_fields->>'25A')::numeric+(p_fields->>'25B')::numeric
 or (p_fields->>'28')::numeric<>(p_fields->>'26')::numeric+(p_fields->>'27')::numeric
 or (p_fields->>'27')::numeric<>0 or (p_fields->>'34')::numeric>90000 or (p_fields->>'34')::numeric>(p_fields->>'20')::numeric
 then raise exception 'form totals inconsistent or unsupported PERA' using errcode='22023'; end if;
 -- Serialize import and approval; no duplicate source or overlapping approved periods.
 lock table app.ph_2316_import in share row exclusive mode;
 select * into old from app.ph_2316_import where organization_id=p_org and user_id=p_user and tax_year=p_year and document_sha256=p_hash;
 if found then
  if (old.issuer_ref,old.period_from,old.period_to,old.fields,old.evidence_reference) is distinct from (p_issuer,p_from,p_to,p_fields,p_reference)
  then raise exception 'document hash conflict' using errcode='22023'; end if;
  return old.id;
 end if;
 insert into app.ph_2316_import(organization_id,user_id,tax_year,issuer_ref,document_sha256,period_from,period_to,fields,evidence_reference,imported_by)
 values(p_org,p_user,p_year,p_issuer,p_hash,p_from,p_to,p_fields,p_reference,auth.uid()) returning id into out_id;
 return out_id;
end $$;
create function app.ph_review_2316(p_org uuid,p_id uuid,p_approve boolean,p_reference text)
returns void language plpgsql set search_path='' as $$
declare i app.ph_2316_import; prev_taxable numeric; prev_withheld numeric;
begin
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 lock table app.ph_2316_import in share row exclusive mode;
 select * into i from app.ph_2316_import where organization_id=p_org and id=p_id;
 if not found or auth.uid() in (i.imported_by,i.user_id) then raise exception 'forbidden' using errcode='42501'; end if;
 if p_approve then
  if exists(select 1 from app.ph_2316_import x join app.ph_2316_review d on d.import_id=x.id and d.approved
  where x.organization_id=i.organization_id and x.user_id=i.user_id and x.tax_year=i.tax_year
  and (x.issuer_ref=i.issuer_ref or x.period_to>=i.period_from))
  then raise exception 'duplicate issuer, overlapping or out-of-order certificate' using errcode='22023'; end if;
  select coalesce(sum((x.fields->>'21')::numeric),0),coalesce(sum((x.fields->>'25A')::numeric),0)
  into prev_taxable,prev_withheld from app.ph_2316_import x join app.ph_2316_review d on d.import_id=x.id and d.approved
  where x.organization_id=i.organization_id and x.user_id=i.user_id and x.tax_year=i.tax_year;
  if ((i.fields->>'22')::numeric<>0 and (i.fields->>'22')::numeric<>prev_taxable)
   or ((i.fields->>'25B')::numeric<>0 and (i.fields->>'25B')::numeric<>prev_withheld)
  then raise exception 'previous-employer totals need reconciliation' using errcode='22023'; end if;
 end if;
 insert into app.ph_2316_review(import_id,approved,review_reference,reviewed_by) values(p_id,p_approve,p_reference,auth.uid());
end $$;
create function app.ph_annual_from_verified_2316(p_org uuid,p_user uuid,p_rule_date date,p_final_pay_date date,p_reason text,
p_current_taxable numeric,p_current_withheld numeric,p_available numeric,p_current_start date,p_completeness_reference text)
returns jsonb language plpgsql stable set search_path='' as $$
declare tax_prior numeric; withheld_prior numeric; form_count bigint; yr int;
begin
 if auth.uid() is null or not app.has_permission(p_org,'payroll.prepare') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_current_start is null or not isfinite(p_current_start) or p_final_pay_date is null or p_current_start>p_final_pay_date
 then raise exception 'current employment dates required' using errcode='22023'; end if;
 yr:=extract(year from p_rule_date)::int;
 if exists(select 1 from app.ph_2316_import i left join app.ph_2316_review r on r.import_id=i.id
 where i.organization_id=p_org and i.user_id=p_user and i.tax_year=yr and (r.import_id is null or (r.approved and i.period_to>=p_current_start)))
 then raise exception 'pending or overlapping source certificate' using errcode='P0001'; end if;
 select coalesce(sum((i.fields->>'21')::numeric),0),coalesce(sum((i.fields->>'25A')::numeric),0),count(*)
 into tax_prior,withheld_prior,form_count from app.ph_2316_import i join app.ph_2316_review r on r.import_id=i.id and r.approved
 where i.organization_id=p_org and i.user_id=p_user and i.tax_year=yr;
 return app.ph_annual_adjustment(p_rule_date,p_final_pay_date,p_reason,p_current_taxable,tax_prior,p_current_withheld,withheld_prior,p_available,p_completeness_reference)
 ||jsonb_build_object('reviewedCertificates',form_count,'previousTaxable',tax_prior,'previousWithheld',withheld_prior);
end $$;
revoke all on function app.ph_open_benefit_year(uuid,uuid,date,jsonb,numeric,text,text),
app.ph_post_benefit(uuid,uuid,text,date,text,numeric,numeric,numeric,text),
app.ph_import_2316(uuid,uuid,integer,text,text,date,date,jsonb,text),app.ph_review_2316(uuid,uuid,boolean,text),
app.ph_annual_from_verified_2316(uuid,uuid,date,date,text,numeric,numeric,numeric,date,text)
from public,anon,authenticated,service_role;
