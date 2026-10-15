-- =============================================================================
-- Talentra schema - 10 Analytics layer and reporting marts (scrum master)
-- Star schema, prefix an_ (rule group 8): an_dim_*, an_fact_*, an_agg_*.
-- Dimensions carry no direct identifiers (names, emails, phones).
-- SCD type 2 on organisation and candidate dimensions; type 1 elsewhere.
-- Deviation (README): an_ tables carry loaded_at instead of created_by/updated_by;
-- they are rebuilt by the ETL job, never edited by users.
-- KPI list is provisional until docket Section 8 is received.
-- =============================================================================
SET search_path = talentra, public;

CREATE TABLE an_dim_date (
    date_key      integer PRIMARY KEY,                  -- yyyymmdd
    calendar_date date NOT NULL CONSTRAINT uq_an_dim_date_calendar_date UNIQUE,
    year          smallint NOT NULL,
    quarter       smallint NOT NULL CHECK (quarter BETWEEN 1 AND 4),
    month         smallint NOT NULL CHECK (month BETWEEN 1 AND 12),
    day_of_month  smallint NOT NULL CHECK (day_of_month BETWEEN 1 AND 31),
    iso_week      smallint NOT NULL CHECK (iso_week BETWEEN 1 AND 53),
    day_of_week   smallint NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),   -- ISO: 1 = Monday
    is_weekend    boolean NOT NULL
);

CREATE PROCEDURE an_load_dim_date(p_from date, p_to date)
LANGUAGE sql AS $$
    INSERT INTO an_dim_date
    SELECT to_char(d, 'YYYYMMDD')::int, d, extract(year FROM d), extract(quarter FROM d), extract(month FROM d),
           extract(day FROM d), extract(week FROM d), extract(isodow FROM d), extract(isodow FROM d) IN (6, 7)
    FROM generate_series(p_from, p_to, interval '1 day') AS g(d)
    ON CONFLICT (date_key) DO NOTHING
$$;

CREATE TABLE an_dim_organisation (
    organisation_key         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organisation_id          bigint NOT NULL,              -- natural key from organisation
    display_name             varchar(200) NOT NULL,
    organisation_type_code   varchar(40) NOT NULL,
    industry_name            varchar(100),                 -- null: not classified
    verification_status_code varchar(40) NOT NULL,
    valid_from               timestamptz NOT NULL,
    valid_to                 timestamptz,                  -- null: current version
    is_current               boolean NOT NULL,
    loaded_at                timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_an_dim_organisation_current CHECK (is_current = (valid_to IS NULL)),
    CONSTRAINT ex_an_dim_organisation_version
        EXCLUDE USING gist (organisation_id WITH =, tstzrange(valid_from, valid_to) WITH &&)
);
CREATE UNIQUE INDEX uq_an_dim_organisation_organisation_id_current ON an_dim_organisation (organisation_id) WHERE is_current;

CREATE TABLE an_dim_candidate (
    candidate_key               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id        bigint NOT NULL,
    experience_band             varchar(20) NOT NULL,      -- 0-1y, 1-3y, 3-5y, 5-10y, 10y+
    city_name                   varchar(100),              -- null: city not given
    state_name                  varchar(100),
    highest_education_level_code varchar(40),              -- null: no education entered
    valid_from                  timestamptz NOT NULL,
    valid_to                    timestamptz,               -- null: current version
    is_current                  boolean NOT NULL,
    loaded_at                   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_an_dim_candidate_current CHECK (is_current = (valid_to IS NULL)),
    CONSTRAINT ex_an_dim_candidate_version
        EXCLUDE USING gist (candidate_profile_id WITH =, tstzrange(valid_from, valid_to) WITH &&)
);
CREATE UNIQUE INDEX uq_an_dim_candidate_candidate_profile_id_current ON an_dim_candidate (candidate_profile_id) WHERE is_current;

CREATE TABLE an_dim_job_requirement (
    job_key               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_requirement_id    bigint NOT NULL CONSTRAINT uq_an_dim_job_requirement_job_requirement_id UNIQUE,
    organisation_key      bigint NOT NULL REFERENCES an_dim_organisation (organisation_key),
    job_category_code     varchar(40) NOT NULL,
    job_role_name         varchar(100),                    -- null: role not mapped
    employment_type_code  varchar(40) NOT NULL,
    work_mode_code        varchar(40) NOT NULL,
    published_date_key    integer REFERENCES an_dim_date (date_key),  -- null: never published
    loaded_at             timestamptz NOT NULL DEFAULT now()
);

-- Grain: one row per application (accumulating snapshot of the pipeline)
CREATE TABLE an_fact_application (
    application_id      bigint PRIMARY KEY,
    job_key             bigint NOT NULL REFERENCES an_dim_job_requirement (job_key),
    candidate_key       bigint NOT NULL REFERENCES an_dim_candidate (candidate_key),
    organisation_key    bigint NOT NULL REFERENCES an_dim_organisation (organisation_key),
    applied_date_key    integer NOT NULL REFERENCES an_dim_date (date_key),
    application_source_code varchar(40) NOT NULL,
    current_stage_code  varchar(40) NOT NULL,
    reached_shortlist   boolean NOT NULL,
    reached_interview   boolean NOT NULL,
    reached_offer       boolean NOT NULL,
    joined              boolean NOT NULL,
    days_to_offer       integer CHECK (days_to_offer >= 0),   -- null: no offer
    days_to_join        integer CHECK (days_to_join >= 0),    -- null: not joined
    loaded_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_an_fact_application_applied_date_key ON an_fact_application (applied_date_key);
CREATE INDEX idx_an_fact_application_organisation_key ON an_fact_application (organisation_key);

-- Grain: one row per wallet ledger entry
CREATE TABLE an_fact_wallet_transaction (
    wallet_ledger_entry_id bigint PRIMARY KEY,
    date_key               integer NOT NULL REFERENCES an_dim_date (date_key),
    organisation_key       bigint REFERENCES an_dim_organisation (organisation_key),  -- null: individual wallet
    ledger_entry_type_code varchar(40) NOT NULL,
    credit_purpose_code    varchar(40),                                               -- null: not a consumption
    credits_delta          integer NOT NULL,
    loaded_at              timestamptz NOT NULL DEFAULT now()
);

-- Grain: one row per payment order
CREATE TABLE an_fact_payment (
    payment_order_id    bigint PRIMARY KEY,
    date_key            integer NOT NULL REFERENCES an_dim_date (date_key),
    organisation_key    bigint REFERENCES an_dim_organisation (organisation_key),     -- null: individual payer
    payment_status_code varchar(40) NOT NULL,
    amount              numeric(14,2) NOT NULL,
    refunded_amount     numeric(14,2) NOT NULL DEFAULT 0,
    currency_code       char(3) NOT NULL,
    loaded_at           timestamptz NOT NULL DEFAULT now()
);

-- Grain: one row per gig assignment
CREATE TABLE an_fact_gig_assignment (
    gig_assignment_id          bigint PRIMARY KEY,
    window_start_date_key      integer NOT NULL REFERENCES an_dim_date (date_key),
    requester_organisation_key bigint REFERENCES an_dim_organisation (organisation_key),  -- null: individual
    gig_assignment_status_code varchar(40) NOT NULL,
    rating_score               numeric(2,1),            -- null: not rated
    total_earning              numeric(14,2),           -- null: not reconciled yet
    currency_code              char(3),
    loaded_at                  timestamptz NOT NULL DEFAULT now()
);

-- Daily hiring funnel by category (KPIs: application volume, stage conversion, joins)
CREATE MATERIALIZED VIEW an_agg_daily_hiring_funnel AS
SELECT f.applied_date_key            AS date_key,
       j.job_category_code,
       count(*)                      AS applications,
       count(*) FILTER (WHERE f.reached_shortlist) AS shortlisted,
       count(*) FILTER (WHERE f.reached_interview) AS interviewed,
       count(*) FILTER (WHERE f.reached_offer)     AS offered,
       count(*) FILTER (WHERE f.joined)            AS joined,
       avg(f.days_to_offer)          AS avg_days_to_offer
FROM an_fact_application f
JOIN an_dim_job_requirement j ON j.job_key = f.job_key
GROUP BY f.applied_date_key, j.job_category_code
WITH NO DATA;
CREATE UNIQUE INDEX uq_an_agg_daily_hiring_funnel_date_category
    ON an_agg_daily_hiring_funnel (date_key, job_category_code);

-- Refresh rule: nightly after the ETL load; CONCURRENTLY keeps readers unblocked
CREATE PROCEDURE an_refresh_aggregates()
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT ispopulated FROM pg_matviews WHERE matviewname = 'an_agg_daily_hiring_funnel') THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY an_agg_daily_hiring_funnel;
    ELSE
        REFRESH MATERIALIZED VIEW an_agg_daily_hiring_funnel;
    END IF;
END $$;
