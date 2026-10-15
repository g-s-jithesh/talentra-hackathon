-- =============================================================================
-- Talentra schema - 05 Gig marketplace (Member B)
-- Design decision: gigs are a SEPARATE subsystem that shares identity,
-- organisation, skills master, wallet and audit with the core, but not the
-- job_requirement / application model. Reasons: time windows and pricing,
-- one-way applications, no hiring pipeline, fulfilment in an external system.
-- Cross-category reporting is done in the analytics layer (10_analytics.sql).
-- =============================================================================
SET search_path = talentra, public;

CREATE TABLE gig_worker_profile (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id           bigint NOT NULL CONSTRAINT uq_gig_worker_profile_user_id UNIQUE REFERENCES app_user (id),
    headline          varchar(200) NOT NULL,
    bio               varchar(4000),                         -- null: not written yet
    base_city_id      integer REFERENCES city (id),          -- null: remote-only worker
    default_rate      money_amount,                          -- null: quotes per service only
    currency_id       smallint REFERENCES currency (id),
    pay_period_id     smallint REFERENCES pay_period (id),
    is_available      boolean NOT NULL DEFAULT true,
    CONSTRAINT ck_gig_worker_profile_rate CHECK (num_nulls(default_rate, currency_id, pay_period_id) IN (0, 3))
);
CALL add_standard_columns('gig_worker_profile', 'soft');
ALTER TABLE gig_worker_profile ADD CONSTRAINT ck_gig_worker_profile_self_registered CHECK (created_by = user_id);

ALTER TABLE profile_project ADD CONSTRAINT fk_profile_project_gig_worker_profile_id
    FOREIGN KEY (gig_worker_profile_id) REFERENCES gig_worker_profile (id) ON DELETE CASCADE;

-- Service offerings with their charge rates
CREATE TABLE gig_worker_service (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gig_worker_profile_id bigint NOT NULL REFERENCES gig_worker_profile (id) ON DELETE CASCADE,
    skill_id              integer NOT NULL REFERENCES skill (id),
    title                 varchar(200) NOT NULL,
    description           varchar(2000),                      -- null: title says it all
    rate                  money_amount NOT NULL,
    currency_id           smallint NOT NULL REFERENCES currency (id),
    pay_period_id         smallint NOT NULL REFERENCES pay_period (id)
);
CALL add_standard_columns('gig_worker_service', 'soft');
CREATE INDEX idx_gig_worker_service_skill_id ON gig_worker_service (skill_id) WHERE deleted_at IS NULL;

CREATE TABLE gig_worker_availability (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gig_worker_profile_id bigint NOT NULL REFERENCES gig_worker_profile (id) ON DELETE CASCADE,
    available_from        timestamptz NOT NULL,
    available_to          timestamptz NOT NULL,
    CONSTRAINT ck_gig_worker_availability_window CHECK (available_to > available_from),
    CONSTRAINT ex_gig_worker_availability_worker_window
        EXCLUDE USING gist (gig_worker_profile_id WITH =, tstzrange(available_from, available_to) WITH &&)
);
CALL add_standard_columns('gig_worker_availability', 'hard');

CREATE TABLE gig_request (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    requester_user_id     bigint NOT NULL REFERENCES app_user (id),
    organisation_id       bigint REFERENCES organisation (id),        -- null: individual requester
    title                 varchar(200) NOT NULL,
    description           text NOT NULL,                              -- unbounded: gig brief
    description_language_id smallint REFERENCES language (id),        -- null: not detected
    work_mode_id          smallint NOT NULL REFERENCES work_mode (id),
    city_id               integer REFERENCES city (id),               -- null: remote gig
    window_start          timestamptz NOT NULL,
    window_end            timestamptz NOT NULL,
    gig_pricing_type_id   smallint NOT NULL REFERENCES gig_pricing_type (id),
    price                 money_amount NOT NULL,                      -- fixed price or rate per pay_period
    currency_id           smallint NOT NULL REFERENCES currency (id),
    pay_period_id         smallint REFERENCES pay_period (id),        -- null for fixed-price gigs
    gig_request_status_id smallint NOT NULL REFERENCES gig_request_status (id),
    CONSTRAINT ck_gig_request_window CHECK (window_end > window_start)
);
CALL add_standard_columns('gig_request', 'soft');
CREATE INDEX idx_gig_request_status_window ON gig_request (gig_request_status_id, window_start) WHERE deleted_at IS NULL;
CREATE INDEX idx_gig_request_requester_user_id ON gig_request (requester_user_id);

CREATE TABLE gig_request_skill (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gig_request_id bigint NOT NULL REFERENCES gig_request (id) ON DELETE CASCADE,
    skill_id       integer NOT NULL REFERENCES skill (id),
    CONSTRAINT uq_gig_request_skill_gig_request_id_skill_id UNIQUE (gig_request_id, skill_id)
);
CALL add_standard_columns('gig_request_skill', 'hard');

-- Workers apply; requesters accept or reject. No counter-bids.
CREATE TABLE gig_application (
    id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gig_request_id            bigint NOT NULL REFERENCES gig_request (id),
    gig_worker_profile_id     bigint NOT NULL REFERENCES gig_worker_profile (id),
    gig_application_status_id smallint NOT NULL REFERENCES gig_application_status (id),
    cover_note                varchar(2000),           -- null: none
    applied_at                timestamptz NOT NULL DEFAULT now(),
    decided_at                timestamptz,             -- null: awaiting requester decision
    decided_by_user_id        bigint REFERENCES app_user (id),
    CONSTRAINT uq_gig_application_gig_request_id_worker UNIQUE (gig_request_id, gig_worker_profile_id),
    CONSTRAINT ck_gig_application_decision CHECK ((decided_at IS NULL) = (decided_by_user_id IS NULL))
);
CALL add_standard_columns('gig_application', 'hard');
CREATE INDEX idx_gig_application_gig_worker_profile_id ON gig_application (gig_worker_profile_id);

-- Accepted application handed off to the external fulfilment system.
-- The window is copied from the request so the exclusion constraint can stop
-- one worker holding overlapping gigs.
CREATE TABLE gig_assignment (
    id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gig_application_id       bigint NOT NULL CONSTRAINT uq_gig_assignment_gig_application_id UNIQUE
                             REFERENCES gig_application (id),
    gig_request_id           bigint NOT NULL REFERENCES gig_request (id),
    gig_worker_profile_id    bigint NOT NULL REFERENCES gig_worker_profile (id),
    window_start             timestamptz NOT NULL,
    window_end               timestamptz NOT NULL,
    gig_assignment_status_id smallint NOT NULL REFERENCES gig_assignment_status (id),
    is_active                boolean NOT NULL DEFAULT true,          -- false once cancelled: frees the window
    fulfilment_reference     varchar(100),                           -- external handoff id; null until handed off
    handed_off_at            timestamptz,
    last_reconciled_at       timestamptz,                            -- null: never reconciled
    CONSTRAINT uq_gig_assignment_fulfilment_reference UNIQUE (fulfilment_reference),
    CONSTRAINT ck_gig_assignment_window CHECK (window_end > window_start),
    CONSTRAINT ck_gig_assignment_handoff CHECK ((fulfilment_reference IS NULL) = (handed_off_at IS NULL)),
    CONSTRAINT ex_gig_assignment_worker_window
        EXCLUDE USING gist (gig_worker_profile_id WITH =, tstzrange(window_start, window_end) WITH &&)
        WHERE (is_active)
);
CALL add_standard_columns('gig_assignment', 'hard');

-- Earnings come from the fulfilment system (integration boundary).
-- Append-only snapshots; (source_system, source_event_id) makes redelivery idempotent.
CREATE TABLE gig_earning_snapshot (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gig_assignment_id bigint NOT NULL REFERENCES gig_assignment (id),
    earning_kind_id   smallint NOT NULL REFERENCES earning_kind (id),   -- estimated / total / projected
    amount            money_amount NOT NULL,
    currency_id       smallint NOT NULL REFERENCES currency (id),
    source_system     varchar(40) NOT NULL,
    source_event_id   varchar(100) NOT NULL,
    as_of             timestamptz NOT NULL,
    CONSTRAINT uq_gig_earning_snapshot_source UNIQUE (source_system, source_event_id)
);
CALL add_standard_columns('gig_earning_snapshot', 'append');
CREATE INDEX idx_gig_earning_snapshot_gig_assignment_id ON gig_earning_snapshot (gig_assignment_id, as_of DESC);

-- Requester's favourite / blacklisted workers (one list per worker at a time)
CREATE TABLE gig_worker_list_entry (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_user_id         bigint NOT NULL REFERENCES app_user (id),
    gig_worker_profile_id bigint NOT NULL REFERENCES gig_worker_profile (id),
    gig_list_type_id      smallint NOT NULL REFERENCES gig_list_type (id),
    note                  varchar(500)                   -- null: none
);
CALL add_standard_columns('gig_worker_list_entry', 'soft');
CREATE UNIQUE INDEX uq_gig_worker_list_entry_owner_worker
    ON gig_worker_list_entry (owner_user_id, gig_worker_profile_id) WHERE deleted_at IS NULL;

-- Requester rates a completed gig
CREATE TABLE gig_rating (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gig_assignment_id bigint NOT NULL CONSTRAINT uq_gig_rating_gig_assignment_id UNIQUE REFERENCES gig_assignment (id),
    rated_by_user_id  bigint NOT NULL REFERENCES app_user (id),
    score             rating_score NOT NULL,
    comment           varchar(2000)                     -- null: score only
);
CALL add_standard_columns('gig_rating', 'hard');
