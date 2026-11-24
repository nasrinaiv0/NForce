\set ON_ERROR_STOP on
begin;
set local lock_timeout='15s';
set local statement_timeout='30s';
select set_config('request.jwt.claim.sub','fb000000-0000-0000-0000-000000000004',true);
do $$ declare j jsonb;begin
 j:=app.ph_post_statutory_journal('fc900000-0000-0000-0000-000000000020','fb000000-0000-0000-0000-000000000002','2026-06-15','sss_reimbursement');
 if (j->>'outstanding')::numeric is distinct from 40000::numeric then raise exception 'reimbursement retry differs';end if;
 raise notice 'P14_RECEIPT_OK';
 perform pg_sleep(1);
end $$;
commit;
