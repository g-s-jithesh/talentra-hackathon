-- =============================================================================
-- Talentra schema - 11 Security (Member A)
-- Database roles, grants, row-level security, column classification,
-- data dictionary view and retention rules.
-- The application connects as a login role that is a member of talentra_app
-- (never as the schema owner, so RLS always applies) and sets app.user_id.
-- =============================================================================
SET search_path = talentra, public;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'talentra_app') THEN
        CREATE ROLE talentra_app NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'talentra_analyst') THEN
        CREATE ROLE talentra_analyst NOLOGIN;
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA talentra TO talentra_app, talentra_analyst;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA talentra TO talentra_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA talentra TO talentra_app;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA talentra FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA talentra TO talentra_app;

-- Append-only tables: no UPDATE / DELETE for the application (triggers back this up)
REVOKE UPDATE, DELETE, TRUNCATE ON
    audit_event, system_error, consent_record, login_attempt, profile_view_event, candidate_activity_event,
    application_stage_history, candidate_search_event, gig_earning_snapshot, payment_event,
    wallet_ledger_entry, profile_download, notification_delivery, support_ticket_message
FROM talentra_app;

-- Written only through SECURITY DEFINER functions
REVOKE INSERT ON audit_event, wallet_ledger_entry, profile_download FROM talentra_app;  -- write_audit, post_wallet_entry, record_profile_download
REVOKE UPDATE ON wallet FROM talentra_app;                                              -- balance moves only via post_wallet_entry
REVOKE INSERT, UPDATE ON user_session FROM talentra_app;                                -- start_session, end_session, revoke_device
REVOKE UPDATE ON application_stage_history FROM talentra_app;
ALTER FUNCTION write_audit(text, text, bigint, jsonb, bigint) SECURITY DEFINER SET search_path = talentra, public;
-- Must see every block entry, although block_entry RLS shows users only their own
ALTER FUNCTION is_blocked_for(bigint) SECURITY DEFINER SET search_path = talentra, public;

-- Analysts read the mart only
GRANT SELECT ON an_dim_date, an_dim_organisation, an_dim_candidate, an_dim_job_requirement, an_fact_application,
                an_fact_wallet_transaction, an_fact_payment, an_fact_gig_assignment, an_agg_daily_hiring_funnel
TO talentra_analyst;

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------
CREATE FUNCTION is_platform_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT has_role('super_admin') OR has_role('admin') $$;
GRANT EXECUTE ON FUNCTION is_platform_admin() TO talentra_app;

-- Job requirements: anyone sees published jobs; recruiters / account admins see and
-- change only their own company's jobs.
ALTER TABLE job_requirement ENABLE ROW LEVEL SECURITY;
CREATE POLICY job_requirement_published ON job_requirement FOR SELECT TO talentra_app
    USING (deleted_at IS NULL AND publish_state_id = (SELECT lookup_id('publish_state', 'published')));
CREATE POLICY job_requirement_own_company ON job_requirement FOR ALL TO talentra_app
    USING (organisation_id IN (SELECT current_user_organisation_ids()))
    WITH CHECK (organisation_id IN (SELECT current_user_organisation_ids()));
CREATE POLICY job_requirement_admin ON job_requirement FOR ALL TO talentra_app
    USING ((SELECT is_platform_admin())) WITH CHECK ((SELECT is_platform_admin()));

-- Candidate profile: owner has full access; others see it only when it is not
-- private and the candidate has not blocked them or their organisation.
ALTER TABLE candidate_profile ENABLE ROW LEVEL SECURITY;
CREATE POLICY candidate_profile_owner ON candidate_profile FOR ALL TO talentra_app
    USING (user_id = current_app_user_id()) WITH CHECK (user_id = current_app_user_id());
CREATE POLICY candidate_profile_visible ON candidate_profile FOR SELECT TO talentra_app
    USING (deleted_at IS NULL
           AND profile_visibility_id <> (SELECT lookup_id('profile_visibility', 'private'))
           AND NOT is_blocked_for(user_id));
CREATE POLICY candidate_profile_admin ON candidate_profile FOR ALL TO talentra_app
    USING ((SELECT is_platform_admin())) WITH CHECK ((SELECT is_platform_admin()));

-- Child tables of a candidate profile inherit its visibility; only the owner writes
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['candidate_contact', 'candidate_address', 'candidate_education', 'candidate_experience',
                             'candidate_skill', 'candidate_language', 'resume_version', 'assessment_attempt',
                             'course_enrolment'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY %I ON %I FOR SELECT TO talentra_app USING (
                            EXISTS (SELECT 1 FROM candidate_profile cp WHERE cp.id = candidate_profile_id))', t || '_visible', t);
        EXECUTE format('CREATE POLICY %I ON %I FOR ALL TO talentra_app
                            USING (EXISTS (SELECT 1 FROM candidate_profile cp
                                           WHERE cp.id = candidate_profile_id AND cp.user_id = current_app_user_id()))
                            WITH CHECK (EXISTS (SELECT 1 FROM candidate_profile cp
                                           WHERE cp.id = candidate_profile_id AND cp.user_id = current_app_user_id()))',
                       t || '_owner', t);
    END LOOP;
END $$;

-- Applications: the candidate, the hiring company (unless blocked), or an admin
ALTER TABLE application ENABLE ROW LEVEL SECURITY;
CREATE POLICY application_candidate ON application FOR ALL TO talentra_app
    USING (EXISTS (SELECT 1 FROM candidate_profile cp
                   WHERE cp.id = candidate_profile_id AND cp.user_id = current_app_user_id()))
    WITH CHECK (EXISTS (SELECT 1 FROM candidate_profile cp
                        WHERE cp.id = candidate_profile_id AND cp.user_id = current_app_user_id()));
CREATE POLICY application_employer ON application FOR ALL TO talentra_app
    USING (EXISTS (SELECT 1 FROM job_requirement j
                   WHERE j.id = job_requirement_id AND j.organisation_id IN (SELECT current_user_organisation_ids()))
           AND EXISTS (SELECT 1 FROM candidate_profile cp WHERE cp.id = candidate_profile_id))
    WITH CHECK (EXISTS (SELECT 1 FROM job_requirement j
                        WHERE j.id = job_requirement_id AND j.organisation_id IN (SELECT current_user_organisation_ids())));
CREATE POLICY application_admin ON application FOR ALL TO talentra_app
    USING ((SELECT is_platform_admin())) WITH CHECK ((SELECT is_platform_admin()));

-- Sourcing requests: the consultant, the hiring company, or an admin
ALTER TABLE sourcing_request ENABLE ROW LEVEL SECURITY;
CREATE POLICY sourcing_request_consultant ON sourcing_request FOR ALL TO talentra_app
    USING (consultant_user_id = current_app_user_id()) WITH CHECK (consultant_user_id = current_app_user_id());
CREATE POLICY sourcing_request_employer ON sourcing_request FOR ALL TO talentra_app
    USING (EXISTS (SELECT 1 FROM job_requirement j
                   WHERE j.id = job_requirement_id AND j.organisation_id IN (SELECT current_user_organisation_ids())));
CREATE POLICY sourcing_request_admin ON sourcing_request FOR ALL TO talentra_app
    USING ((SELECT is_platform_admin())) WITH CHECK ((SELECT is_platform_admin()));

-- Block lists are private to the blocker (the blocked party must not learn of them)
ALTER TABLE block_entry ENABLE ROW LEVEL SECURITY;
CREATE POLICY block_entry_blocker ON block_entry FOR ALL TO talentra_app
    USING (blocker_user_id = current_app_user_id()) WITH CHECK (blocker_user_id = current_app_user_id());
CREATE POLICY block_entry_admin ON block_entry FOR SELECT TO talentra_app USING ((SELECT is_platform_admin()));

-- Who viewed / downloaded a profile: the candidate, the acting company, admins
ALTER TABLE profile_view_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY profile_view_event_read ON profile_view_event FOR SELECT TO talentra_app
    USING (viewer_user_id = current_app_user_id()
           OR viewer_organisation_id IN (SELECT current_user_organisation_ids())
           OR EXISTS (SELECT 1 FROM candidate_profile cp WHERE cp.id = candidate_profile_id AND cp.user_id = current_app_user_id())
           OR (SELECT is_platform_admin()));
CREATE POLICY profile_view_event_insert ON profile_view_event FOR INSERT TO talentra_app
    WITH CHECK (viewer_user_id = current_app_user_id()
                AND EXISTS (SELECT 1 FROM candidate_profile cp WHERE cp.id = candidate_profile_id));

ALTER TABLE profile_download ENABLE ROW LEVEL SECURITY;
CREATE POLICY profile_download_read ON profile_download FOR SELECT TO talentra_app
    USING (organisation_id IN (SELECT current_user_organisation_ids())
           OR EXISTS (SELECT 1 FROM candidate_profile cp WHERE cp.id = candidate_profile_id AND cp.user_id = current_app_user_id())
           OR (SELECT is_platform_admin()));

-- Audit trail: platform admins only
ALTER TABLE audit_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_event_admin ON audit_event FOR SELECT TO talentra_app USING ((SELECT is_platform_admin()));

-- -----------------------------------------------------------------------------
-- Sensitive data classification (rule group 6). Columns not listed are Internal.
-- -----------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        -- Sensitive: credentials, national / tax identifiers, payment references (encrypted, hashed or tokenised)
        ('user_credential', 'password_hash', 'Sensitive', 'argon2id hash'),
        ('user_session', 'token_hash', 'Sensitive', 'SHA-256 of token'),
        ('identity_verification', 'verification_token', 'Sensitive', 'provider token, no raw id stored'),
        ('identity_verification', 'document_last4', 'Sensitive', 'masked'),
        ('organisation_tax_identifier', 'identifier_ciphertext', 'Sensitive', 'AES-256-GCM, key in KMS'),
        ('organisation_tax_identifier', 'identifier_hash', 'Sensitive', 'HMAC-SHA256'),
        ('organisation_tax_identifier', 'identifier_masked', 'Sensitive', 'masked'),
        ('payment_order', 'gateway_order_reference', 'Sensitive', 'gateway token'),
        ('payment_event', 'gateway_event_id', 'Sensitive', 'gateway token'),
        ('refund', 'gateway_refund_reference', 'Sensitive', 'gateway token'),
        -- Personal: identifies a person; access-controlled and audited
        ('app_user', 'email', 'Personal', NULL), ('app_user', 'phone', 'Personal', NULL),
        ('app_user', 'display_name', 'Personal', NULL),
        ('candidate_profile', 'full_name', 'Personal', NULL), ('candidate_profile', 'preferred_name', 'Personal', NULL),
        ('candidate_profile', 'date_of_birth', 'Personal', NULL), ('candidate_profile', 'gender_id', 'Personal', NULL),
        ('candidate_profile', 'summary', 'Personal', NULL),
        ('candidate_contact', 'email', 'Personal', NULL), ('candidate_contact', 'phone', 'Personal', NULL),
        ('candidate_address', 'address_line1', 'Personal', NULL), ('candidate_address', 'address_line2', 'Personal', NULL),
        ('candidate_address', 'postal_code', 'Personal', NULL),
        ('candidate_experience', 'description', 'Personal', NULL),
        ('resume_version', 'content_text', 'Personal', NULL), ('resume_version', 'file_storage_key', 'Personal', NULL),
        ('gig_worker_profile', 'bio', 'Personal', NULL),
        ('referral', 'referred_email', 'Personal', NULL),
        ('login_attempt', 'email_attempted', 'Personal', NULL), ('login_attempt', 'ip_address', 'Personal', NULL),
        ('user_device', 'device_fingerprint_hash', 'Personal', NULL),
        ('user_session', 'ip_address', 'Personal', NULL),
        ('consent_record', 'source_ip', 'Personal', NULL),
        ('audit_event', 'ip_address', 'Personal', NULL),
        ('community_post', 'body', 'Personal', NULL),
        ('support_ticket', 'description', 'Personal', NULL),
        -- Public: shown without restriction
        ('job_requirement', 'title', 'Public', NULL), ('job_requirement', 'description', 'Public', NULL),
        ('organisation', 'display_name', 'Public', NULL), ('organisation', 'website_url', 'Public', NULL),
        ('gig_request', 'title', 'Public', NULL), ('gig_request', 'description', 'Public', NULL),
        ('faq_translation', 'question', 'Public', NULL), ('faq_translation', 'answer', 'Public', NULL)
    ) AS v(table_name, column_name, data_class, protection) LOOP
        EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', r.table_name, r.column_name,
                       'class=' || r.data_class || coalesce('; protection=' || r.protection, ''));
    END LOOP;
END $$;

-- Data dictionary generated from the catalog: every column with type, domain,
-- nullability and class.
CREATE VIEW data_dictionary AS
SELECT c.relname                                                    AS table_name,
       a.attnum                                                     AS column_position,
       a.attname                                                    AS column_name,
       format_type(a.atttypid, a.atttypmod)                         AS data_type,
       NOT a.attnotnull                                             AS is_nullable,
       coalesce(substring(d.description FROM 'class=(\w+)'), 'Internal') AS data_class,
       substring(d.description FROM 'protection=(.*)$')            AS protection
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'talentra'
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
LEFT JOIN pg_description d ON d.objoid = c.oid AND d.objsubid = a.attnum
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition;

-- -----------------------------------------------------------------------------
-- Retention rules (rule group 4), executed by a nightly job
-- -----------------------------------------------------------------------------
CREATE TABLE data_retention_rule (
    id            smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name    varchar(63) NOT NULL,
    trigger_event varchar(40) NOT NULL CHECK (trigger_event IN ('deletion_request', 'inactivity', 'age')),
    retain_for    interval NOT NULL,
    action        varchar(20) NOT NULL CHECK (action IN ('anonymise', 'hard_delete', 'drop_partition')),
    notes         varchar(300),                   -- null: none
    CONSTRAINT uq_data_retention_rule_table_name_trigger_event UNIQUE (table_name, trigger_event)
);
CALL add_standard_columns('data_retention_rule', 'hard');
