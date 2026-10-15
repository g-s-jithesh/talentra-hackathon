-- =============================================================================
-- Talentra schema - 00 foundation
-- Engine: PostgreSQL 16+ (built and tested on 18.6)
-- Contents: extensions, session context, standard domains, standard-column and
--           lookup helpers, i18n, all enumeration (lookup) tables, master data.
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- EXCLUDE constraints mixing = and &&
CREATE SCHEMA IF NOT EXISTS talentra;
SET search_path = talentra, public;

-- -----------------------------------------------------------------------------
-- Session context. The access layer sets app.user_id once per transaction:
--   SELECT set_config('app.user_id', '42', true);
-- It feeds created_by / updated_by defaults and every RLS policy.
-- -----------------------------------------------------------------------------
CREATE FUNCTION current_app_user_id() RETURNS bigint
LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('app.user_id', true), '')::bigint $$;

-- -----------------------------------------------------------------------------
-- Standard domains (rule group 3)
-- -----------------------------------------------------------------------------
CREATE DOMAIN person_name   AS varchar(150);                       -- no script / word-order assumption
CREATE DOMAIN email_address AS varchar(254)
    CHECK (VALUE = lower(VALUE) AND VALUE ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');
CREATE DOMAIN phone_e164    AS varchar(16) CHECK (VALUE ~ '^\+[1-9][0-9]{6,14}$');
CREATE DOMAIN money_amount  AS numeric(14,2) CHECK (VALUE >= 0);   -- never float; pair with currency_id
CREATE DOMAIN percentage    AS numeric(5,2)  CHECK (VALUE BETWEEN 0 AND 100);
CREATE DOMAIN rating_score  AS numeric(2,1)  CHECK (VALUE BETWEEN 1 AND 5);
CREATE DOMAIN latitude      AS numeric(9,6)  CHECK (VALUE BETWEEN -90 AND 90);
CREATE DOMAIN longitude     AS numeric(9,6)  CHECK (VALUE BETWEEN -180 AND 180);
CREATE DOMAIN credit_count  AS integer;                            -- wallet credits, whole units

-- -----------------------------------------------------------------------------
-- Row-stamping and append-only helpers (rule groups 4 and 10)
-- -----------------------------------------------------------------------------
CREATE FUNCTION stamp_row() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.updated_at := NEW.created_at;
        NEW.updated_by := coalesce(NEW.updated_by, NEW.created_by);
    ELSE
        NEW.created_at := OLD.created_at;          -- creation stamp is immutable
        NEW.created_by := OLD.created_by;
        NEW.updated_at := now();
        NEW.updated_by := coalesce(current_app_user_id(), NEW.updated_by);
    END IF;
    RETURN NEW;
END $$;

CREATE FUNCTION forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: record a correcting entry instead', TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation';
END $$;

CREATE PROCEDURE make_append_only(p_table regclass)
LANGUAGE plpgsql AS $$
DECLARE rel text := (SELECT relname FROM pg_class WHERE oid = p_table);
BEGIN
    EXECUTE format('CREATE TRIGGER trg_%s_append_only BEFORE UPDATE OR DELETE ON %s
                    FOR EACH ROW EXECUTE FUNCTION forbid_mutation()', rel, p_table);
    EXECUTE format('CREATE TRIGGER trg_%s_no_truncate BEFORE TRUNCATE ON %s
                    FOR EACH STATEMENT EXECUTE FUNCTION forbid_mutation()', rel, p_table);
END $$;

-- p_mode: 'soft'   = audit columns + deleted_at (soft delete, active view v_<table>)
--         'hard'   = audit columns, rows are physically deleted
--         'append' = created_at/created_by only, UPDATE/DELETE/TRUNCATE rejected
CREATE PROCEDURE add_standard_columns(p_table regclass, p_mode text DEFAULT 'soft')
LANGUAGE plpgsql AS $$
DECLARE rel text := (SELECT relname FROM pg_class WHERE oid = p_table);
BEGIN
    IF p_mode NOT IN ('soft', 'hard', 'append') THEN
        RAISE EXCEPTION 'unknown mode %', p_mode;
    END IF;
    EXECUTE format('ALTER TABLE %s
        ADD COLUMN created_at timestamptz NOT NULL DEFAULT now(),
        ADD COLUMN created_by bigint NOT NULL DEFAULT current_app_user_id() REFERENCES app_user(id)', p_table);
    IF p_mode = 'append' THEN
        CALL make_append_only(p_table);
        RETURN;
    END IF;
    EXECUTE format('ALTER TABLE %s
        ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
        ADD COLUMN updated_by bigint NOT NULL REFERENCES app_user(id)', p_table);
    EXECUTE format('CREATE TRIGGER trg_%s_stamp BEFORE INSERT OR UPDATE ON %s
                    FOR EACH ROW EXECUTE FUNCTION stamp_row()', rel, p_table);
    IF p_mode = 'soft' THEN
        EXECUTE format('ALTER TABLE %s ADD COLUMN deleted_at timestamptz', p_table);  -- null: live row
        EXECUTE format('CREATE VIEW %I WITH (security_invoker = true) AS
                        SELECT * FROM %s WHERE deleted_at IS NULL', 'v_' || rel, p_table);
    END IF;
END $$;

-- Monthly range partitions <parent>_pYYYYMM plus <parent>_pdefault (rule group 8)
CREATE PROCEDURE create_monthly_partitions(p_parent regclass, p_first date, p_months int)
LANGUAGE plpgsql AS $$
DECLARE
    rel text := (SELECT relname FROM pg_class WHERE oid = p_parent);
    m   date;
BEGIN
    FOR i IN 0 .. p_months - 1 LOOP
        m := date_trunc('month', p_first)::date + make_interval(months => i);
        EXECUTE format('CREATE TABLE %I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
                       rel || '_p' || to_char(m, 'YYYYMM'), p_parent, m, m + interval '1 month');
    END LOOP;
    EXECUTE format('CREATE TABLE %I PARTITION OF %s DEFAULT', rel || '_pdefault', p_parent);
END $$;

-- -----------------------------------------------------------------------------
-- app_user is created first: every table's created_by references it.
-- Its lookup / language FKs are added at the end of this file (deferrable, so the
-- system user and the first lookup rows can be seeded in one transaction).
-- -----------------------------------------------------------------------------
CREATE TABLE app_user (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email                 email_address NOT NULL,
    phone                 phone_e164,                   -- null: no phone given
    phone_country_id      smallint,                     -- null only when phone is null
    display_name          person_name NOT NULL,
    preferred_language_id smallint NOT NULL,
    account_status_id     smallint NOT NULL,
    is_system             boolean NOT NULL DEFAULT false,
    last_login_at         timestamptz,                  -- null: never logged in
    CONSTRAINT ck_app_user_phone_country CHECK ((phone IS NULL) = (phone_country_id IS NULL))
);
CALL add_standard_columns('app_user', 'soft');
CREATE UNIQUE INDEX uq_app_user_email ON app_user (email) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- Multilingual UI data (rule group 7)
-- -----------------------------------------------------------------------------
CREATE TABLE ui_label (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    label_key varchar(120) NOT NULL CONSTRAINT uq_ui_label_label_key UNIQUE
              CHECK (label_key ~ '^[a-z0-9_.]+$')
);
CALL add_standard_columns('ui_label', 'hard');

CREATE TABLE language (
    id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    iso_code    varchar(10) NOT NULL CONSTRAINT uq_language_iso_code UNIQUE,   -- BCP 47, e.g. en, hi, ta
    ui_label_id bigint NOT NULL REFERENCES ui_label (id),
    native_name varchar(60) NOT NULL,
    is_default  boolean NOT NULL DEFAULT false,      -- fallback language for missing translations
    is_active   boolean NOT NULL DEFAULT true,
    sort_order  smallint NOT NULL DEFAULT 0
);
CALL add_standard_columns('language', 'hard');
CREATE UNIQUE INDEX uq_language_is_default ON language (is_default) WHERE is_default;

CREATE TABLE ui_translation (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ui_label_id     bigint NOT NULL REFERENCES ui_label (id) ON DELETE CASCADE,
    language_id     smallint NOT NULL REFERENCES language (id),
    translated_text varchar(1000) NOT NULL,
    CONSTRAINT uq_ui_translation_ui_label_id_language_id UNIQUE (ui_label_id, language_id)
);
CALL add_standard_columns('ui_translation', 'hard');

-- Translation with fallback to the default language
CREATE FUNCTION ui_text(p_ui_label_id bigint, p_language_id smallint) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT t.translated_text
    FROM ui_translation t JOIN language l ON l.id = t.language_id
    WHERE t.ui_label_id = p_ui_label_id
      AND (t.language_id = p_language_id OR l.is_default)
    ORDER BY (t.language_id = p_language_id) DESC
    LIMIT 1
$$;

-- -----------------------------------------------------------------------------
-- Enumerations: one lookup table per enumeration, identical shape
-- (code, display name per language via ui_label, active flag, sort order).
-- -----------------------------------------------------------------------------
CREATE PROCEDURE create_lookup(p_name text)
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format($f$
        CREATE TABLE %I (
            id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            code        varchar(40) NOT NULL CONSTRAINT %I UNIQUE CHECK (code ~ '^[a-z][a-z0-9_]*$'),
            ui_label_id bigint NOT NULL REFERENCES ui_label (id),
            is_active   boolean NOT NULL DEFAULT true,
            sort_order  smallint NOT NULL DEFAULT 0
        )$f$, p_name, 'uq_' || p_name || '_code');
    CALL add_standard_columns(p_name::regclass, 'hard');
END $$;

-- Resolve a lookup code to its id; used by functions and seed scripts
CREATE FUNCTION lookup_id(p_table text, p_code text) RETURNS smallint
LANGUAGE plpgsql STABLE AS $$
DECLARE v smallint;
BEGIN
    EXECUTE format('SELECT id FROM %I WHERE code = $1', p_table) INTO v USING p_code;
    IF v IS NULL THEN
        RAISE EXCEPTION 'unknown code %.%', p_table, p_code;
    END IF;
    RETURN v;
END $$;

DO $$
DECLARE n text;
BEGIN
    FOREACH n IN ARRAY ARRAY[
        -- identity, organisation, administration
        'account_status', 'verification_status', 'organisation_type', 'tax_identifier_type',
        'identity_document_type', 'consent_purpose', 'error_severity', 'session_end_reason', 'device_type',
        -- profile
        'gender', 'proficiency_level', 'education_level', 'contact_type', 'profile_visibility',
        'activity_type', 'enrolment_status', 'referral_status',
        -- jobs and applications
        'job_category', 'employment_type', 'work_mode', 'job_status', 'publish_state',
        'application_stage', 'application_source', 'interview_mode', 'interview_outcome', 'offer_status',
        'salary_disclosure', 'pay_period', 'question_type',
        -- sourcing, notifications, community
        'sourcing_request_status', 'channel', 'delivery_status', 'notification_category',
        'alert_frequency', 'reaction_type', 'ticket_status', 'ticket_priority', 'faq_category',
        -- gig marketplace
        'gig_pricing_type', 'gig_request_status', 'gig_application_status', 'gig_assignment_status',
        'gig_list_type', 'earning_kind',
        -- subscriptions, payments, wallet
        'subscription_status', 'billing_period', 'payment_status', 'refund_status', 'invoice_status',
        'ledger_entry_type', 'credit_purpose', 'entitlement_type'
    ] LOOP
        CALL create_lookup(n);
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Master data. Names of places, skills and roles are proper nouns / technical
-- terms stored once in their canonical form (deviation from rule 7 recorded in
-- README: they are data, not UI strings).
-- -----------------------------------------------------------------------------
CREATE TABLE country (
    id           smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    iso2_code    char(2) NOT NULL CONSTRAINT uq_country_iso2_code UNIQUE CHECK (iso2_code ~ '^[A-Z]{2}$'),
    iso3_code    char(3) NOT NULL CONSTRAINT uq_country_iso3_code UNIQUE CHECK (iso3_code ~ '^[A-Z]{3}$'),
    name         varchar(100) NOT NULL,
    dialing_code varchar(5) NOT NULL CHECK (dialing_code ~ '^\+[0-9]{1,4}$'),
    is_active    boolean NOT NULL DEFAULT true
);
CALL add_standard_columns('country', 'hard');

CREATE TABLE state (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_id smallint NOT NULL REFERENCES country (id),
    code       varchar(10) NOT NULL,
    name       varchar(100) NOT NULL,
    CONSTRAINT uq_state_country_id_code UNIQUE (country_id, code)
);
CALL add_standard_columns('state', 'hard');

CREATE TABLE city (
    id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    state_id          integer NOT NULL REFERENCES state (id),
    name              varchar(100) NOT NULL,
    latitude          latitude,             -- null: not geocoded yet (geolocation is optional)
    longitude         longitude,
    coordinate_source varchar(40),          -- e.g. 'geonames'; null with the coordinates
    CONSTRAINT uq_city_state_id_name UNIQUE (state_id, name),
    CONSTRAINT ck_city_coordinates CHECK (num_nulls(latitude, longitude, coordinate_source) IN (0, 3))
);
CALL add_standard_columns('city', 'hard');

CREATE TABLE currency (
    id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    iso_code    char(3) NOT NULL CONSTRAINT uq_currency_iso_code UNIQUE CHECK (iso_code ~ '^[A-Z]{3}$'),
    name        varchar(60) NOT NULL,
    minor_units smallint NOT NULL DEFAULT 2 CHECK (minor_units BETWEEN 0 AND 3)
);
CALL add_standard_columns('currency', 'hard');

CREATE TABLE industry (
    id                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_industry_id integer REFERENCES industry (id),   -- null: top-level sector
    name               varchar(100) NOT NULL CONSTRAINT uq_industry_name UNIQUE
);
CALL add_standard_columns('industry', 'soft');

CREATE TABLE job_role (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    industry_id integer REFERENCES industry (id),           -- null: cross-industry role
    name        varchar(100) NOT NULL CONSTRAINT uq_job_role_name UNIQUE
);
CALL add_standard_columns('job_role', 'soft');

CREATE TABLE skill (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_skill_id integer REFERENCES skill (id),          -- null: top-level skill
    name            varchar(100) NOT NULL,
    normalized_name varchar(100) GENERATED ALWAYS AS (lower(btrim(name))) STORED,
    CONSTRAINT uq_skill_normalized_name UNIQUE (normalized_name)
);
CALL add_standard_columns('skill', 'soft');

CREATE TABLE qualification (
    id                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    education_level_id smallint NOT NULL REFERENCES education_level (id),
    name               varchar(150) NOT NULL CONSTRAINT uq_qualification_name UNIQUE
);
CALL add_standard_columns('qualification', 'soft');

-- app_user FKs now that their targets exist
ALTER TABLE app_user
    ADD CONSTRAINT fk_app_user_preferred_language_id FOREIGN KEY (preferred_language_id)
        REFERENCES language (id) DEFERRABLE INITIALLY DEFERRED,
    ADD CONSTRAINT fk_app_user_account_status_id FOREIGN KEY (account_status_id)
        REFERENCES account_status (id) DEFERRABLE INITIALLY DEFERRED,
    ADD CONSTRAINT fk_app_user_phone_country_id FOREIGN KEY (phone_country_id)
        REFERENCES country (id);
