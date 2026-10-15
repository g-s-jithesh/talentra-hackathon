-- =============================================================================
-- Talentra schema - 90 reference data
-- System user, default language, every enumeration code, roles, base master
-- data, plans and retention rules. Runs as one transaction: app_user's
-- language / status FKs are deferred until the lookups exist.
-- =============================================================================
BEGIN;
SET LOCAL search_path = talentra, public;
SELECT set_config('app.user_id', '1', true);

INSERT INTO app_user (email, display_name, preferred_language_id, account_status_id, is_system)
VALUES ('system@talentra.local', 'System', 1, 1, true);          -- becomes id 1

-- Label with an English translation; returns the label id
CREATE FUNCTION pg_temp.label(p_key text, p_text text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
    INSERT INTO talentra.ui_label (label_key) VALUES (p_key) RETURNING id INTO v;
    INSERT INTO talentra.ui_translation (ui_label_id, language_id, translated_text)
    VALUES (v, (SELECT id FROM talentra.language WHERE iso_code = 'en'), p_text);
    RETURN v;
END $$;

-- English first: it is the default language and id 1
INSERT INTO ui_label (label_key) VALUES ('language.en');
INSERT INTO language (iso_code, ui_label_id, native_name, is_default, sort_order)
VALUES ('en', (SELECT id FROM ui_label WHERE label_key = 'language.en'), 'English', true, 1);
INSERT INTO ui_translation (ui_label_id, language_id, translated_text)
VALUES ((SELECT id FROM ui_label WHERE label_key = 'language.en'), 1, 'English');
INSERT INTO language (iso_code, ui_label_id, native_name, sort_order) VALUES
    ('hi', pg_temp.label('language.hi', 'Hindi'), 'हिन्दी', 2),
    ('ta', pg_temp.label('language.ta', 'Tamil'), 'தமிழ்', 3),
    ('te', pg_temp.label('language.te', 'Telugu'), 'తెలుగు', 4);

CREATE FUNCTION pg_temp.seed_lookup(p_table text, p_codes text[]) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    FOR i IN 1 .. array_length(p_codes, 1) LOOP
        EXECUTE format('INSERT INTO talentra.%I (code, ui_label_id, sort_order) VALUES ($1, $2, $3)', p_table)
        USING p_codes[i],
              pg_temp.label('lookup.' || p_table || '.' || p_codes[i], initcap(replace(p_codes[i], '_', ' '))),
              i;
    END LOOP;
END $$;

SELECT pg_temp.seed_lookup(t, c) FROM (VALUES
    ('account_status',          ARRAY['active', 'suspended', 'blocked', 'closed']),
    ('verification_status',     ARRAY['pending', 'verified', 'rejected', 'expired']),
    ('organisation_type',       ARRAY['employer', 'client', 'consultancy', 'campus']),
    ('tax_identifier_type',     ARRAY['gstin', 'pan', 'cin', 'tan']),
    ('identity_document_type',  ARRAY['aadhaar', 'pan', 'passport', 'voter_id', 'driving_licence']),
    ('consent_purpose',         ARRAY['terms_of_service', 'privacy_policy', 'profile_sharing', 'marketing', 'data_processing']),
    ('error_severity',          ARRAY['info', 'warning', 'error', 'critical']),
    ('session_end_reason',      ARRAY['logout', 'expired', 'revoked', 'replaced']),
    ('device_type',             ARRAY['web', 'android', 'ios', 'desktop']),
    ('gender',                  ARRAY['female', 'male', 'non_binary', 'prefer_not_to_say']),
    ('proficiency_level',       ARRAY['beginner', 'intermediate', 'advanced', 'expert', 'native']),
    ('education_level',         ARRAY['secondary', 'higher_secondary', 'diploma', 'bachelors', 'masters', 'doctorate']),
    ('contact_type',            ARRAY['email', 'phone', 'whatsapp']),
    ('profile_visibility',      ARRAY['public', 'recruiters_only', 'private']),
    ('activity_type',           ARRAY['login', 'profile_update', 'resume_upload', 'resume_download', 'application_submit']),
    ('enrolment_status',        ARRAY['enrolled', 'in_progress', 'completed', 'dropped']),
    ('referral_status',         ARRAY['sent', 'registered', 'applied', 'hired', 'expired']),
    ('job_category',            ARRAY['gig', 'general_staffing', 'professional_staffing', 'permanent', 'apprentice',
                                      'campus', 'consultant_marketplace', 'managed_remote']),
    ('employment_type',         ARRAY['full_time', 'part_time', 'contract', 'temporary', 'internship', 'apprenticeship']),
    ('work_mode',               ARRAY['onsite', 'remote', 'hybrid']),
    ('job_status',              ARRAY['draft', 'open', 'on_hold', 'closed', 'filled', 'cancelled']),
    ('publish_state',           ARRAY['unpublished', 'published', 'expired']),
    ('application_stage',       ARRAY['applied', 'shortlisted', 'interviewed', 'offered', 'joined', 'rejected', 'withdrawn']),
    ('application_source',      ARRAY['direct', 'recruiter_sourced', 'consultant', 'referral', 'campus_drive']),
    ('interview_mode',          ARRAY['in_person', 'video', 'phone']),
    ('interview_outcome',       ARRAY['passed', 'failed', 'no_show', 'rescheduled']),
    ('offer_status',            ARRAY['draft', 'extended', 'accepted', 'declined', 'revoked', 'expired']),
    ('salary_disclosure',       ARRAY['disclosed', 'not_disclosed', 'not_applicable']),
    ('pay_period',              ARRAY['hour', 'day', 'week', 'month', 'year', 'fixed']),
    ('question_type',           ARRAY['free_text', 'single_choice', 'multiple_choice', 'yes_no', 'number']),
    ('sourcing_request_status', ARRAY['requested', 'accepted', 'declined', 'withdrawn', 'closed']),
    ('channel',                 ARRAY['email', 'sms', 'whatsapp', 'in_app', 'push']),
    ('delivery_status',         ARRAY['queued', 'sent', 'delivered', 'read', 'failed', 'bounced']),
    ('notification_category',   ARRAY['job_alert', 'application_update', 'message', 'billing', 'security', 'system']),
    ('alert_frequency',         ARRAY['instant', 'daily', 'weekly']),
    ('reaction_type',           ARRAY['like', 'helpful', 'insightful']),
    ('ticket_status',           ARRAY['open', 'in_progress', 'waiting_on_user', 'resolved', 'closed']),
    ('ticket_priority',         ARRAY['low', 'medium', 'high', 'urgent']),
    ('faq_category',            ARRAY['account', 'jobs', 'billing', 'gigs', 'privacy']),
    ('gig_pricing_type',        ARRAY['fixed', 'rate']),
    ('gig_request_status',      ARRAY['draft', 'open', 'filled', 'closed', 'cancelled']),
    ('gig_application_status',  ARRAY['applied', 'accepted', 'rejected', 'withdrawn']),
    ('gig_assignment_status',   ARRAY['handed_off', 'in_progress', 'completed', 'cancelled', 'disputed']),
    ('gig_list_type',           ARRAY['favourite', 'blacklist']),
    ('earning_kind',            ARRAY['estimated', 'total', 'projected']),
    ('subscription_status',     ARRAY['trial', 'active', 'past_due', 'cancelled', 'expired']),
    ('billing_period',          ARRAY['monthly', 'quarterly', 'yearly', 'one_time']),
    ('payment_status',          ARRAY['created', 'pending', 'captured', 'failed', 'refunded', 'partially_refunded']),
    ('refund_status',           ARRAY['requested', 'processing', 'completed', 'failed']),
    ('invoice_status',          ARRAY['issued', 'paid', 'void']),
    ('ledger_entry_type',       ARRAY['recharge', 'consumption', 'refund', 'reversal', 'grant']),
    ('credit_purpose',          ARRAY['job_posting', 'profile_download', 'outreach']),
    ('entitlement_type',        ARRAY['job_posting', 'profile_download', 'outreach_message', 'featured_job', 'user_seat'])
) AS v(t, c);

-- Actors from docket Section 3
INSERT INTO role (code, ui_label_id, is_organisation_scoped)
SELECT code, pg_temp.label('role.' || code, initcap(replace(code, '_', ' '))), scoped
FROM (VALUES ('super_admin', false), ('admin', false), ('account_admin', true), ('guest', false),
             ('candidate', false), ('employer', true), ('recruiter', true), ('consultant', false),
             ('placement_officer', true)) AS v(code, scoped);

INSERT INTO permission (code, ui_label_id)
SELECT code, pg_temp.label('permission.' || code, code)
FROM unnest(ARRAY['job_requirement.create', 'job_requirement.publish', 'application.move_stage',
                  'candidate.search', 'candidate.download', 'candidate.outreach', 'sourcing.request',
                  'sourcing.decide', 'wallet.recharge', 'user.block', 'organisation.verify',
                  'audit.read', 'licence.manage']) AS code;

INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM role r JOIN permission p ON
    (r.code IN ('super_admin', 'admin'))
 OR (r.code = 'recruiter'     AND p.code IN ('job_requirement.create', 'job_requirement.publish', 'application.move_stage',
                                             'candidate.search', 'candidate.download', 'candidate.outreach', 'sourcing.decide'))
 OR (r.code = 'employer'      AND p.code LIKE 'job_requirement.%')
 OR (r.code = 'account_admin' AND p.code IN ('wallet.recharge', 'licence.manage', 'sourcing.decide'))
 OR (r.code = 'consultant'    AND p.code IN ('sourcing.request', 'candidate.search'))
 OR (r.code = 'candidate'     AND p.code = 'user.block');

-- Base master data (the generator loads the full lists)
INSERT INTO country (iso2_code, iso3_code, name, dialing_code) VALUES ('IN', 'IND', 'India', '+91');
INSERT INTO currency (iso_code, name, minor_units) VALUES ('INR', 'Indian Rupee', 2), ('USD', 'US Dollar', 2);
INSERT INTO state (country_id, code, name) VALUES (1, 'TN', 'Tamil Nadu'), (1, 'KA', 'Karnataka'), (1, 'MH', 'Maharashtra');
INSERT INTO city (state_id, name, latitude, longitude, coordinate_source) VALUES
    (1, 'Chennai', 13.082700, 80.270700, 'geonames'),
    (2, 'Bengaluru', 12.971600, 77.594600, 'geonames'),
    (3, 'Mumbai', 19.076000, 72.877700, 'geonames');

INSERT INTO subscription_plan (code, ui_label_id, price, currency_id, billing_period_id, max_users, max_devices_per_user, included_credits)
VALUES ('free',     pg_temp.label('plan.free', 'Free'),         0,     1, lookup_id('billing_period', 'monthly'), 1, 2, 0),
       ('pro',      pg_temp.label('plan.pro', 'Pro'),           4999,  1, lookup_id('billing_period', 'monthly'), 5, 2, 100),
       ('business', pg_temp.label('plan.business', 'Business'), 19999, 1, lookup_id('billing_period', 'monthly'), 25, 3, 600);

INSERT INTO data_retention_rule (table_name, trigger_event, retain_for, action, notes) VALUES
    ('candidate_profile',        'deletion_request', interval '30 days',  'anonymise',      'grace period, then names/contacts cleared'),
    ('candidate_profile',        'inactivity',       interval '3 years',  'anonymise',      NULL),
    ('candidate_activity_event', 'age',              interval '2 years',  'hard_delete',    NULL),
    ('candidate_search_event',   'age',              interval '1 year',   'hard_delete',    NULL),
    ('login_attempt',            'age',              interval '1 year',   'hard_delete',    NULL),
    ('notification_delivery',    'age',              interval '6 months', 'drop_partition', 'status only; bodies never stored'),
    ('audit_event',              'age',              interval '7 years',  'drop_partition', 'statutory retention');

COMMIT;
