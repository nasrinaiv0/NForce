-- Private candidate, no client grants or integration. Full snapshots, not mutable current membership.
create table app.ph_employment_history (
  organization_id uuid not null,
  user_id uuid not null,
  effective_on date not null check (isfinite(effective_on)),
  recorded_at timestamptz not null default clock_timestamp() check (isfinite(recorded_at)),
  status text not null check (status in ('employed','separated')),
  pay_basis text,
  rate_php numeric,
  site_reference text,
  wage_order_reference text,
  evidence_reference text not null check (length(btrim(evidence_reference)) between 1 and 300),
  recorded_by uuid not null references auth.users(id),
  primary key (organization_id,user_id,effective_on,recorded_at),
  foreign key (organization_id,user_id) references public.memberships(organization_id,user_id),
  check ((status='separated' and pay_basis is null and rate_php is null and site_reference is null and wage_order_reference is null)
    or (status='employed' and pay_basis is not null and pay_basis in ('hourly','daily','monthly')
      and rate_php is not null and rate_php::text not in ('NaN','Infinity','-Infinity') and rate_php>0 and rate_php<=1000000000 and rate_php=round(rate_php,2)
      and site_reference is not null and length(btrim(site_reference)) between 1 and 300
      and wage_order_reference is not null and length(btrim(wage_order_reference)) between 1 and 300))
);
alter table app.ph_employment_history enable row level security;
revoke all on app.ph_employment_history from public,anon,authenticated,service_role;
create trigger ph_employment_immutable before update or delete on app.ph_employment_history
for each row execute function app.forbid_mutation();
create function app.ph_employment_as_of(p_org uuid,p_user uuid,p_day date,p_known_at timestamptz)
returns app.ph_employment_history language plpgsql stable set search_path='' as $$
declare r app.ph_employment_history;
begin
  if p_org is null or p_user is null or p_day is null or not isfinite(p_day) or p_known_at is null or not isfinite(p_known_at) then
    raise exception 'invalid history lookup' using errcode='22023';
  end if;
  select * into r from app.ph_employment_history
  where organization_id=p_org and user_id=p_user and effective_on<=p_day and recorded_at<=p_known_at
  order by effective_on desc,recorded_at desc limit 1;
  if not found then raise exception 'historical employment evidence missing' using errcode='P0001'; end if;
  return r;
end $$;
revoke all on function app.ph_employment_as_of(uuid,uuid,date,timestamptz) from public,anon,authenticated,service_role;
