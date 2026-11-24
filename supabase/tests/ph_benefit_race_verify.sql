\set ON_ERROR_STOP on
do $$ begin
if not exists(select 1 from app.ph_benefit_event
where organization_id='fb100000-0000-0000-0000-000000000001' and user_id='fb000000-0000-0000-0000-000000000002' and tax_year=2026
group by organization_id,user_id,tax_year
having count(*)=2 and sum((result->>'deMinimisExempt')::numeric)=2500 and sum((result->>'taxable')::numeric)=1500
and min(sequence_no)=1 and max(sequence_no)=2)
then raise exception 'benefit concurrent cap invariant failed'; end if;
raise notice 'ok - independent benefit transactions share one monthly cap; retries do not consume twice';
end $$;
