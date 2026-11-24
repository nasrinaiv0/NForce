\set ON_ERROR_STOP on
do $$ declare o uuid:='fb100000-0000-0000-0000-000000000088';begin
if (select count(*) from app.ph_money_reversal where organization_id=o)<>1
or (select count(*) from app.ph_money_reversal_journal where organization_id=o)<>9
or (select sum(debit-credit) from app.ph_money_reversal_journal where organization_id=o)<>0
or exists(select 1 from app.ph_money_journal j join app.ph_money_reversal_journal r using(organization_id,user_id,pay_month,account_code) where j.organization_id=o and (j.debit<>r.credit or j.credit<>r.debit))
or (select count(*) from public.audit_events where organization_id=o and action='accounting.ph_money_reversed')<>1
then raise exception 'concurrent reversal invariant failed';end if;
raise notice 'ok - concurrent reversal creates one balanced inverse journal and one audit event';
end $$;
