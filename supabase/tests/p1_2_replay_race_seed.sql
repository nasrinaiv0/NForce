\set ON_ERROR_STOP on
begin;
create function pg_temp.u(i int) returns uuid language sql as $$ select ('fb000000-0000-0000-0000-00000000000'||i)::uuid $$;
\ir p1_2_cutoff_fixture.sql
select pg_temp.seed9(11,'daily','2026-09-15','daily',540,true,'rice');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_cutoff_2026(pg_temp.org9(11),pg_temp.u(2),'2026-09-15');
select pg_temp.attest(pg_temp.org9(11),'reversal','2026-09-15','{"undispatched":true,"reason":"fictional concurrency correction"}');
select app.ph_post_canonical_reversal(pg_temp.org9(11),pg_temp.u(2),'2026-09-15');
select pg_temp.attest(pg_temp.org9(11),'replay','2026-09-15',
 (select a.payload||jsonb_build_object('taxableExtras',1200,'reason','correct fictional supplement','undispatched',true,'originalAttestation',a.id) from app.ph_payroll_attestation a where a.organization_id=pg_temp.org9(11) and a.kind='period'));

select pg_temp.seed9(14,'monthly','2026-02-01','monthly',30000,false,'none');
select set_config('request.jwt.claim.sub',pg_temp.u(4)::text,true);
select app.ph_post_cutoff_2026(pg_temp.org9(14),pg_temp.u(2),'2026-02-01');
select pg_temp.attest(pg_temp.org9(14),'reversal','2026-02-01','{"undispatched":true,"reason":"fictional monthly concurrent correction"}');
select app.ph_post_canonical_reversal(pg_temp.org9(14),pg_temp.u(2),'2026-02-01');
select pg_temp.attest(pg_temp.org9(14),'replay','2026-02-01',(select a.payload||jsonb_build_object('taxableExtras',1000,'reason','fictional corrected supplement','undispatched',true,'originalAttestation',a.id) from app.ph_payroll_attestation a where a.organization_id=pg_temp.org9(14) and a.kind='period'));
commit;
