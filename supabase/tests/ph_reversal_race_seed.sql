\set ON_ERROR_STOP on
select set_config('request.jwt.claim.sub','fb000000-0000-0000-0000-000000000001',false);
select app.ph_propose_reversal('fb100000-0000-0000-0000-000000000088','fb000000-0000-0000-0000-000000000002','2025-01-01','fictional correction','reviewed unsent accrual');
