\set ON_ERROR_STOP on
do $$ declare o uuid:='fb100000-0000-0000-0000-000000000088'; begin
if (select count(*) from app.ph_money_snapshot where organization_id=o)<>1
or (select count(*) from app.ph_money_journal where organization_id=o)<>9
or (select sum(debit) from app.ph_money_journal where organization_id=o)<>34338.22
or (select sum(credit) from app.ph_money_journal where organization_id=o)<>34338.22
or (select count(*) from public.audit_events where organization_id=o and action='accounting.ph_money_posted')<>1
then raise exception 'monthly monetary race invariant failed'; end if;
raise notice 'ok - concurrent monetary postings return one immutable snapshot, one balanced journal and one audit event';
end $$;
