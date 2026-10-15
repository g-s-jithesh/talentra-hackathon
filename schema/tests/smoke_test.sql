-- Behaviour checks for the Talentra rules. Run on a freshly built database:
--   psql -d talentra -f schema/tests/smoke_test.sql
-- Every check prints "ok: ..."; the first failure stops the script.
\set ON_ERROR_STOP on
SET client_min_messages = notice;
SET search_path = talentra, public;

CREATE FUNCTION pg_temp.expect_error(p_sql text, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'ok: % -> %', p_label, SQLERRM;
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: % did not raise', p_label;
END $$;

CREATE FUNCTION pg_temp.expect(p_ok boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', p_label; END IF;
    RAISE NOTICE 'ok: %', p_label;
END $$;

-- ---------------------------------------------------------------- fixtures
SELECT set_config('app.user_id', '1', false);
INSERT INTO app_user (email, display_name, preferred_language_id, account_status_id) VALUES
    ('rec.a@acme.test',  'Recruiter A', 1, lookup_id('account_status', 'active')),   -- 2
    ('rec.b@beta.test',  'Recruiter B', 1, lookup_id('account_status', 'active')),   -- 3
    ('cand@mail.test',   'Candidate',   1, lookup_id('account_status', 'active')),   -- 4
    ('cons@agency.test', 'Consultant',  1, lookup_id('account_status', 'active'));   -- 5
INSERT INTO user_role (user_id, role_id) VALUES
    (2, (SELECT id FROM role WHERE code = 'recruiter')), (3, (SELECT id FROM role WHERE code = 'recruiter')),
    (4, (SELECT id FROM role WHERE code = 'candidate')), (5, (SELECT id FROM role WHERE code = 'consultant'));
INSERT INTO organisation (organisation_type_id, legal_name, display_name, verification_status_id, account_status_id) VALUES
    (lookup_id('organisation_type', 'employer'), 'Acme Pvt Ltd', 'Acme', lookup_id('verification_status', 'verified'), lookup_id('account_status', 'active')),
    (lookup_id('organisation_type', 'employer'), 'Beta Pvt Ltd', 'Beta', lookup_id('verification_status', 'verified'), lookup_id('account_status', 'active'));
INSERT INTO organisation_recruiter (organisation_id, user_id) VALUES (1, 2), (2, 3);

SELECT set_config('app.user_id', '4', false);   -- candidate registers themself
INSERT INTO candidate_profile (user_id, full_name, salary_disclosure_id, profile_visibility_id)
VALUES (4, 'Priya Raman', lookup_id('salary_disclosure', 'not_disclosed'), lookup_id('profile_visibility', 'public'));
INSERT INTO block_entry (blocker_user_id, blocked_organisation_id) VALUES (4, 2);   -- candidate blocks Beta

SELECT set_config('app.user_id', '2', false);
INSERT INTO job_requirement (organisation_id, posted_by_user_id, job_category_id, title, description, employment_type_id,
                             work_mode_id, positions_total, salary_disclosure_id, job_status_id, publish_state_id)
VALUES (1, 2, lookup_id('job_category', 'permanent'), 'Data Engineer', 'Build pipelines', lookup_id('employment_type', 'full_time'),
        lookup_id('work_mode', 'hybrid'), 2, lookup_id('salary_disclosure', 'not_applicable'),
        lookup_id('job_status', 'open'), lookup_id('publish_state', 'unpublished'));

-- ---------------------------------------------------------------- domain and check rules
SELECT set_config('app.user_id', '1', false);
SELECT pg_temp.expect_error($$INSERT INTO app_user (email, display_name, preferred_language_id, account_status_id)
                              VALUES ('Upper@Case.test', 'X', 1, 1)$$, 'email must be lowercase');
SELECT pg_temp.expect_error($$UPDATE app_user SET phone = '98765', phone_country_id = 1 WHERE id = 2$$, 'phone must be E.164');
SELECT pg_temp.expect_error($$UPDATE job_requirement SET salary_min = 100000, salary_max = 200000, currency_id = 1, pay_period_id = 5
                              WHERE id = 1$$, 'salary amounts rejected when salary_disclosure = not_applicable');
SELECT pg_temp.expect_error($$UPDATE job_requirement SET positions_filled = 3 WHERE id = 1$$, 'positions_filled cannot exceed positions_total');
SELECT pg_temp.expect_error($$INSERT INTO candidate_profile (user_id, full_name, salary_disclosure_id, profile_visibility_id)
                              VALUES (5, 'Created By Someone Else', lookup_id('salary_disclosure', 'not_disclosed'),
                                      lookup_id('profile_visibility', 'public'))$$, 'recruiter / admin cannot register a candidate');
SELECT pg_temp.expect_error($$UPDATE organisation SET parent_organisation_id = 2 WHERE id = 1;
                              UPDATE organisation SET parent_organisation_id = 1 WHERE id = 2$$, 'organisation hierarchy cycle');
SELECT pg_temp.expect_error($$INSERT INTO organisation_recruiter (organisation_id, user_id) VALUES (2, 2)$$,
                            'recruiter mapped to two companies at once');

-- ---------------------------------------------------------------- append-only
SELECT write_audit('test.event', 'app_user', 1);
SELECT pg_temp.expect_error($$UPDATE audit_event SET action_code = 'tampered'$$, 'audit_event UPDATE rejected');
SELECT pg_temp.expect_error($$DELETE FROM audit_event$$, 'audit_event DELETE rejected');

-- ---------------------------------------------------------------- licences, seats, devices
INSERT INTO licence (organisation_id, max_users, max_devices_per_user) VALUES (1, 1, 1);
INSERT INTO licence_seat (licence_id, user_id) VALUES (1, 2);
SELECT pg_temp.expect_error($$INSERT INTO licence_seat (licence_id, user_id) VALUES (1, 3)$$, 'seat limit (max_users = 1)');
SELECT pg_temp.expect(start_session(2, '\x01', 'web', '\xaa') IS NOT NULL, 'first device gets a session');
SELECT pg_temp.expect(start_session(2, '\x01', 'web', '\xab') IS NOT NULL, 'same device can open another session');
SELECT pg_temp.expect(start_session(2, '\x02', 'android', '\xac') IS NULL, 'second device refused (max_devices_per_user = 1)');
SELECT pg_temp.expect(EXISTS (SELECT 1 FROM audit_event WHERE action_code = 'session.device_limit_refused'),
                      'refused login recorded in the audit trail');
SELECT pg_temp.expect(EXISTS (SELECT 1 FROM login_attempt WHERE failure_reason = 'device_limit'),
                      'refused login recorded in login history');
SELECT end_session(id, 'revoked') FROM user_session WHERE user_id = 2;
SELECT pg_temp.expect(start_session(2, '\x02', 'android', '\xad') IS NOT NULL, 'revoked sessions free the device slot');

-- ---------------------------------------------------------------- no overlapping periods
INSERT INTO subscription (licence_id, subscription_plan_id, subscription_status_id)
VALUES (1, (SELECT id FROM subscription_plan WHERE code = 'pro'), lookup_id('subscription_status', 'active'));
INSERT INTO subscription_period (subscription_id, licence_id, period_start, period_end) VALUES (1, 1, '2026-10-01', '2026-11-01');
SELECT pg_temp.expect_error($$INSERT INTO subscription_period (subscription_id, licence_id, period_start, period_end)
                              VALUES (1, 1, '2026-10-20', '2026-11-20')$$, 'overlapping subscription periods');
INSERT INTO subscription_period (subscription_id, licence_id, period_start, period_end, is_renewal)
VALUES (1, 1, '2026-11-01', '2026-12-01', true);
SELECT pg_temp.expect(true, 'back-to-back renewal period accepted');

SELECT set_config('app.user_id', '5', false);
INSERT INTO gig_worker_profile (user_id, headline) VALUES (5, 'Data annotator');
SELECT set_config('app.user_id', '2', false);
INSERT INTO gig_request (requester_user_id, organisation_id, title, description, work_mode_id, window_start, window_end,
                         gig_pricing_type_id, price, currency_id, gig_request_status_id)
SELECT 2, 1, 'Gig ' || g, 'Label images', lookup_id('work_mode', 'remote'),
       '2026-10-20 09:00+05:30'::timestamptz + (g - 1) * interval '4 hours',
       '2026-10-20 17:00+05:30'::timestamptz + (g - 1) * interval '4 hours',
       lookup_id('gig_pricing_type', 'fixed'), 5000, 1, lookup_id('gig_request_status', 'open')
FROM generate_series(1, 2) g;
INSERT INTO gig_application (gig_request_id, gig_worker_profile_id, gig_application_status_id)
SELECT id, 1, lookup_id('gig_application_status', 'accepted') FROM gig_request;
INSERT INTO gig_assignment (gig_application_id, gig_request_id, gig_worker_profile_id, window_start, window_end, gig_assignment_status_id)
SELECT a.id, r.id, 1, r.window_start, r.window_end, lookup_id('gig_assignment_status', 'handed_off')
FROM gig_application a JOIN gig_request r ON r.id = a.gig_request_id WHERE r.title = 'Gig 1';
SELECT pg_temp.expect_error($$INSERT INTO gig_assignment (gig_application_id, gig_request_id, gig_worker_profile_id, window_start, window_end, gig_assignment_status_id)
                              SELECT a.id, r.id, 1, r.window_start, r.window_end, lookup_id('gig_assignment_status', 'handed_off')
                              FROM gig_application a JOIN gig_request r ON r.id = a.gig_request_id WHERE r.title = 'Gig 2'$$,
                            'gig windows cannot overlap for the same worker');

-- ---------------------------------------------------------------- consultants
SELECT pg_temp.expect_error($$INSERT INTO sourcing_request (job_requirement_id, consultant_user_id, sourcing_request_status_id)
                              VALUES (1, 5, lookup_id('sourcing_request_status', 'requested'))$$,
                            'consultant cannot act on a job closed to consultants');
UPDATE job_requirement SET is_open_to_consultants = true WHERE id = 1;
INSERT INTO sourcing_request (job_requirement_id, consultant_user_id, sourcing_request_status_id)
VALUES (1, 5, lookup_id('sourcing_request_status', 'requested'));
SELECT pg_temp.expect_error($$INSERT INTO sourcing_request (job_requirement_id, consultant_user_id, sourcing_request_status_id)
                              VALUES (1, 4, lookup_id('sourcing_request_status', 'requested'))$$,
                            'non-consultant cannot raise a sourcing request');

-- ---------------------------------------------------------------- wallet and downloads
SELECT set_config('app.user_id', '1', false);
INSERT INTO wallet (organisation_id) VALUES (1), (2);
SELECT set_config('app.user_id', '2', false);
SELECT pg_temp.expect_error($$SELECT record_profile_download(1, 1)$$, 'download refused with zero credits');
SELECT post_wallet_entry(1, 5, 'recharge');
SELECT record_profile_download(1, 1);
SELECT pg_temp.expect((SELECT balance FROM wallet WHERE id = 1) = 4, 'download deducted one credit');
SELECT pg_temp.expect((SELECT count(*) FROM profile_download) = 1
                      AND EXISTS (SELECT 1 FROM audit_event WHERE action_code = 'profile.download'),
                      'download history + audit written');
SELECT pg_temp.expect_error($$UPDATE wallet_ledger_entry SET credits_delta = 500$$, 'ledger UPDATE rejected');
SELECT post_wallet_entry(1, 1, 'reversal', NULL, NULL, (SELECT max(id) FROM wallet_ledger_entry), 'download refunded');
SELECT pg_temp.expect((SELECT balance FROM wallet WHERE id = 1) = 5, 'correction is a new reversing entry');
SELECT pg_temp.expect_error($$SELECT post_wallet_entry(1, -100, 'consumption', 'outreach')$$, 'balance can never go negative');
SELECT set_config('app.user_id', '3', false);
SELECT post_wallet_entry(2, 5, 'recharge');
SELECT pg_temp.expect_error($$SELECT record_profile_download(1, 2)$$, 'blocked company cannot download the candidate');

-- ---------------------------------------------------------------- row-level security (as the app role)
SET ROLE talentra_app;
SELECT set_config('app.user_id', '3', false);   -- recruiter at Beta (blocked by the candidate)
SELECT pg_temp.expect((SELECT count(*) FROM candidate_profile) = 0, 'blocked company cannot see the candidate');
SELECT pg_temp.expect((SELECT count(*) FROM block_entry) = 0, 'blocked party cannot see the block list');
SELECT pg_temp.expect((SELECT count(*) FROM job_requirement) = 0, 'recruiter cannot see another company''s unpublished job');
UPDATE job_requirement SET title = 'hijacked';
SELECT set_config('app.user_id', '2', false);   -- recruiter at Acme
SELECT pg_temp.expect((SELECT count(*) FROM candidate_profile) = 1, 'other recruiters can see the candidate');
SELECT pg_temp.expect((SELECT title FROM job_requirement WHERE id = 1) = 'Data Engineer', 'other company''s update affected nothing');
SELECT pg_temp.expect((SELECT count(*) FROM audit_event) = 0, 'non-admin cannot read the audit trail');
SELECT pg_temp.expect_error($$INSERT INTO audit_event (action_code, entity_table) VALUES ('forged', 'x')$$,
                            'app cannot write audit rows directly');
SELECT pg_temp.expect_error($$UPDATE wallet SET balance = 1000000$$, 'app cannot edit wallet balance');
SELECT set_config('app.user_id', '4', false);   -- the candidate
SELECT pg_temp.expect((SELECT count(*) FROM block_entry) = 1, 'blocker sees own block list');
RESET ROLE;

SELECT pg_temp.expect(true, 'ALL CHECKS PASSED');
