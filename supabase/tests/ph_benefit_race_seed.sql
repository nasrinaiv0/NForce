\set ON_ERROR_STOP on
select set_config('request.jwt.claim.sub','fb000000-0000-0000-0000-000000000001',false);
select app.ph_open_benefit_year('fb100000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-000000000002','2026-01-05','{}',90000,'monthly','fictional concurrent benefit seed');
