-- =============================================================================
-- Talentra schema - 04 Jobs and applications (common module, whole team)
-- Job requirement lifecycle, questionnaires, applications and their pipeline,
-- interviews, offers, candidate search history.
-- application and application_stage_history are hash-partitioned on
-- job_requirement_id (16 partitions): the hot path is "pipeline of one job",
-- uniqueness (job, candidate) stays enforceable, and 100M rows split evenly.
-- =============================================================================
SET search_path = talentra, public;

CREATE TABLE job_requirement (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organisation_id        bigint NOT NULL REFERENCES organisation (id),     -- employer / client
    posted_by_user_id      bigint NOT NULL REFERENCES app_user (id),
    job_category_id        smallint NOT NULL REFERENCES job_category (id),
    job_role_id            integer REFERENCES job_role (id),                 -- null: role not mapped
    title                  varchar(200) NOT NULL,
    description            text NOT NULL,                                    -- unbounded: job description
    description_language_id smallint REFERENCES language (id),               -- null: language not detected
    employment_type_id     smallint NOT NULL REFERENCES employment_type (id),
    work_mode_id           smallint NOT NULL REFERENCES work_mode (id),
    positions_total        smallint NOT NULL CHECK (positions_total > 0),
    positions_filled       smallint NOT NULL DEFAULT 0,
    experience_min_months  smallint NOT NULL DEFAULT 0 CHECK (experience_min_months >= 0),
    experience_max_months  smallint,                                         -- null: no upper limit
    salary_disclosure_id   smallint NOT NULL REFERENCES salary_disclosure (id),
    salary_min             money_amount,                                     -- null unless disclosed
    salary_max             money_amount,
    currency_id            smallint REFERENCES currency (id),
    pay_period_id          smallint REFERENCES pay_period (id),
    job_status_id          smallint NOT NULL REFERENCES job_status (id),
    publish_state_id       smallint NOT NULL REFERENCES publish_state (id),
    published_at           timestamptz,                                      -- null: never published
    expires_at             timestamptz,                                      -- null: no expiry set
    is_open_to_consultants boolean NOT NULL DEFAULT false,
    questionnaire_id       bigint,                                           -- FK below; null: no screening questions
    CONSTRAINT ck_job_requirement_positions CHECK (positions_filled BETWEEN 0 AND positions_total),
    CONSTRAINT ck_job_requirement_experience CHECK (experience_max_months >= experience_min_months),
    CONSTRAINT ck_job_requirement_salary_fields CHECK (num_nulls(salary_min, salary_max, currency_id, pay_period_id) IN (0, 4)),
    CONSTRAINT ck_job_requirement_salary_range CHECK (salary_max >= salary_min),
    CONSTRAINT ck_job_requirement_expiry CHECK (expires_at > published_at)
);
CALL add_standard_columns('job_requirement', 'soft');
CREATE TRIGGER trg_job_requirement_salary BEFORE INSERT OR UPDATE ON job_requirement
    FOR EACH ROW EXECUTE FUNCTION check_salary_disclosure();
CREATE INDEX idx_job_requirement_organisation_id ON job_requirement (organisation_id, job_status_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_job_requirement_search ON job_requirement (job_category_id, job_role_id, published_at DESC)
    WHERE deleted_at IS NULL AND published_at IS NOT NULL;
CREATE INDEX idx_job_requirement_title_fts ON job_requirement USING gin (to_tsvector('simple', title));

CREATE TABLE job_requirement_location (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_requirement_id bigint NOT NULL REFERENCES job_requirement (id) ON DELETE CASCADE,
    city_id            integer NOT NULL REFERENCES city (id),
    positions          smallint CHECK (positions > 0),      -- null: not split by location
    CONSTRAINT uq_job_requirement_location_job_requirement_id_city_id UNIQUE (job_requirement_id, city_id)
);
CALL add_standard_columns('job_requirement_location', 'hard');
CREATE INDEX idx_job_requirement_location_city_id ON job_requirement_location (city_id);

CREATE TABLE job_requirement_skill (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_requirement_id bigint NOT NULL REFERENCES job_requirement (id) ON DELETE CASCADE,
    skill_id           integer NOT NULL REFERENCES skill (id),
    is_mandatory       boolean NOT NULL DEFAULT true,
    min_years          numeric(4,1) CHECK (min_years >= 0),   -- null: no minimum
    CONSTRAINT uq_job_requirement_skill_job_requirement_id_skill_id UNIQUE (job_requirement_id, skill_id)
);
CALL add_standard_columns('job_requirement_skill', 'hard');
CREATE INDEX idx_job_requirement_skill_skill_id ON job_requirement_skill (skill_id);

-- Screening questionnaires, reusable across an organisation's jobs
CREATE TABLE questionnaire (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organisation_id bigint NOT NULL REFERENCES organisation (id),
    title           varchar(200) NOT NULL
);
CALL add_standard_columns('questionnaire', 'soft');
ALTER TABLE job_requirement ADD CONSTRAINT fk_job_requirement_questionnaire_id
    FOREIGN KEY (questionnaire_id) REFERENCES questionnaire (id);

CREATE TABLE questionnaire_question (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    questionnaire_id bigint NOT NULL REFERENCES questionnaire (id) ON DELETE CASCADE,
    question_type_id smallint NOT NULL REFERENCES question_type (id),
    prompt           varchar(1000) NOT NULL,
    is_required      boolean NOT NULL DEFAULT true,
    sort_order       smallint NOT NULL DEFAULT 0
);
CALL add_standard_columns('questionnaire_question', 'hard');

CREATE TABLE question_option (
    id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    questionnaire_question_id bigint NOT NULL REFERENCES questionnaire_question (id) ON DELETE CASCADE,
    option_text               varchar(300) NOT NULL,
    sort_order                smallint NOT NULL DEFAULT 0
);
CALL add_standard_columns('question_option', 'hard');

-- ---------------------------------------------------------------------------
-- Applications (partitioned)
-- ---------------------------------------------------------------------------
CREATE TABLE application (
    id                    bigint GENERATED ALWAYS AS IDENTITY,
    job_requirement_id    bigint NOT NULL REFERENCES job_requirement (id),
    candidate_profile_id  bigint NOT NULL REFERENCES candidate_profile (id),
    application_stage_id  smallint NOT NULL REFERENCES application_stage (id),
    application_source_id smallint NOT NULL REFERENCES application_source (id),
    sourcing_request_id   bigint,                         -- FK added in 08; null: not sourced by a consultant
    resume_version_id     bigint REFERENCES resume_version (id),   -- null: applied without a resume
    applied_at            timestamptz NOT NULL DEFAULT now(),
    stage_changed_at      timestamptz NOT NULL DEFAULT now(),
    cover_note            varchar(2000),                  -- null: none
    PRIMARY KEY (id, job_requirement_id),
    CONSTRAINT uq_application_job_requirement_id_candidate_profile_id UNIQUE (job_requirement_id, candidate_profile_id)
) PARTITION BY HASH (job_requirement_id);
CALL add_standard_columns('application', 'hard');
DO $$ BEGIN
    FOR i IN 0 .. 15 LOOP
        EXECUTE format('CREATE TABLE application_h%s PARTITION OF application FOR VALUES WITH (MODULUS 16, REMAINDER %s)',
                       lpad(i::text, 2, '0'), i);
    END LOOP;
END $$;
CREATE INDEX idx_application_candidate_profile_id ON application (candidate_profile_id, applied_at DESC);
CREATE INDEX idx_application_job_requirement_id_stage ON application (job_requirement_id, application_stage_id, stage_changed_at DESC);

CREATE TABLE application_answer (
    id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id            bigint NOT NULL,
    job_requirement_id        bigint NOT NULL,
    questionnaire_question_id bigint NOT NULL REFERENCES questionnaire_question (id),
    answer_text               varchar(4000),                                   -- set for free-text questions
    question_option_id        bigint REFERENCES question_option (id),          -- set for choice questions
    FOREIGN KEY (application_id, job_requirement_id) REFERENCES application (id, job_requirement_id) ON DELETE CASCADE,
    CONSTRAINT uq_application_answer_application_id_question
        UNIQUE NULLS NOT DISTINCT (application_id, questionnaire_question_id, question_option_id),
    CONSTRAINT ck_application_answer_value CHECK (num_nonnulls(answer_text, question_option_id) = 1)
);
CALL add_standard_columns('application_answer', 'hard');

-- Pipeline history (append-only): applied -> shortlisted -> interviewed -> offered -> joined / rejected
CREATE TABLE application_stage_history (
    id                   bigint GENERATED ALWAYS AS IDENTITY,
    application_id       bigint NOT NULL,
    job_requirement_id   bigint NOT NULL,
    from_stage_id        smallint REFERENCES application_stage (id),   -- null: first stage
    to_stage_id          smallint NOT NULL REFERENCES application_stage (id),
    reason               varchar(500),                                 -- rejection / withdrawal reason; null: none
    PRIMARY KEY (id, job_requirement_id),
    FOREIGN KEY (application_id, job_requirement_id) REFERENCES application (id, job_requirement_id)
) PARTITION BY HASH (job_requirement_id);
CALL add_standard_columns('application_stage_history', 'append');
DO $$ BEGIN
    FOR i IN 0 .. 15 LOOP
        EXECUTE format('CREATE TABLE application_stage_history_h%s PARTITION OF application_stage_history
                        FOR VALUES WITH (MODULUS 16, REMAINDER %s)', lpad(i::text, 2, '0'), i);
    END LOOP;
END $$;
CREATE INDEX idx_application_stage_history_application_id ON application_stage_history (application_id, created_at);

-- Stage changes go through here so history and current stage never drift
CREATE FUNCTION move_application_stage(p_application_id bigint, p_job_requirement_id bigint,
                                       p_to_stage_code text, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_from smallint;
        v_to   smallint := lookup_id('application_stage', p_to_stage_code);
BEGIN
    SELECT application_stage_id INTO v_from FROM application
    WHERE id = p_application_id AND job_requirement_id = p_job_requirement_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'application % not found', p_application_id; END IF;
    UPDATE application SET application_stage_id = v_to, stage_changed_at = now()
    WHERE id = p_application_id AND job_requirement_id = p_job_requirement_id;
    INSERT INTO application_stage_history (application_id, job_requirement_id, from_stage_id, to_stage_id, reason)
    VALUES (p_application_id, p_job_requirement_id, v_from, v_to, p_reason);
END $$;

CREATE TABLE interview (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id       bigint NOT NULL,
    job_requirement_id   bigint NOT NULL,
    round_number         smallint NOT NULL CHECK (round_number > 0),
    interview_mode_id    smallint NOT NULL REFERENCES interview_mode (id),
    scheduled_at         timestamptz NOT NULL,
    duration_minutes     smallint NOT NULL DEFAULT 60 CHECK (duration_minutes BETWEEN 5 AND 600),
    interviewer_user_id  bigint REFERENCES app_user (id),                -- null: external interviewer
    interview_outcome_id smallint REFERENCES interview_outcome (id),     -- null: not held yet
    feedback             varchar(4000),                                  -- null: not written yet
    FOREIGN KEY (application_id, job_requirement_id) REFERENCES application (id, job_requirement_id),
    CONSTRAINT uq_interview_application_id_round_number UNIQUE (application_id, round_number)
);
CALL add_standard_columns('interview', 'soft');

CREATE TABLE offer (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id       bigint NOT NULL,
    job_requirement_id   bigint NOT NULL,
    offer_status_id      smallint NOT NULL REFERENCES offer_status (id),
    salary_disclosure_id smallint NOT NULL REFERENCES salary_disclosure (id),
    salary_min           money_amount,          -- offered CTC; min = max for a fixed offer; null unless disclosed
    salary_max           money_amount,
    currency_id          smallint REFERENCES currency (id),
    pay_period_id        smallint REFERENCES pay_period (id),
    offered_at           timestamptz NOT NULL DEFAULT now(),
    joining_date         date,                  -- null: not agreed yet
    joined_at            timestamptz,           -- null: not joined
    FOREIGN KEY (application_id, job_requirement_id) REFERENCES application (id, job_requirement_id),
    CONSTRAINT ck_offer_salary_fields CHECK (num_nulls(salary_min, salary_max, currency_id, pay_period_id) IN (0, 4)),
    CONSTRAINT ck_offer_salary_range CHECK (salary_max >= salary_min)
);
CALL add_standard_columns('offer', 'soft');
CREATE TRIGGER trg_offer_salary BEFORE INSERT OR UPDATE ON offer
    FOR EACH ROW EXECUTE FUNCTION check_salary_disclosure();
CREATE INDEX idx_offer_application_id ON offer (application_id);

-- Candidate job search history
CREATE TABLE candidate_search_event (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id      bigint NOT NULL REFERENCES app_user (id),
    keywords     varchar(200),                    -- null: filter-only search
    filters      jsonb NOT NULL DEFAULT '{}',     -- city, role, salary ... as submitted by the UI
    result_count integer NOT NULL CHECK (result_count >= 0),
    searched_at  timestamptz NOT NULL DEFAULT now()
);
CALL add_standard_columns('candidate_search_event', 'append');
CREATE INDEX idx_candidate_search_event_user_id ON candidate_search_event (user_id, searched_at DESC);

-- Deferred FKs from 03
ALTER TABLE candidate_bookmark ADD CONSTRAINT fk_candidate_bookmark_job_requirement_id
    FOREIGN KEY (job_requirement_id) REFERENCES job_requirement (id);
ALTER TABLE referral ADD CONSTRAINT fk_referral_job_requirement_id
    FOREIGN KEY (job_requirement_id) REFERENCES job_requirement (id);

-- FK indexes added by Milestone 2 validation (B7)
CREATE INDEX idx_job_requirement_posted_by_user_id ON job_requirement (posted_by_user_id);
CREATE INDEX idx_job_requirement_questionnaire_id ON job_requirement (questionnaire_id) WHERE questionnaire_id IS NOT NULL;
CREATE INDEX idx_questionnaire_organisation_id ON questionnaire (organisation_id);
CREATE INDEX idx_questionnaire_question_questionnaire_id ON questionnaire_question (questionnaire_id);
CREATE INDEX idx_question_option_questionnaire_question_id ON question_option (questionnaire_question_id);
CREATE INDEX idx_application_answer_questionnaire_question_id ON application_answer (questionnaire_question_id);
CREATE INDEX idx_interview_interviewer_user_id ON interview (interviewer_user_id) WHERE interviewer_user_id IS NOT NULL;
CREATE INDEX idx_application_sourcing_request_id ON application (sourcing_request_id) WHERE sourcing_request_id IS NOT NULL;
