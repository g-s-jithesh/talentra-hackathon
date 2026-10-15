-- =============================================================================
-- Talentra schema - 03 Profile (common module, whole team)
-- Candidate identity, contacts, education, experience, skills, languages,
-- resumes, assessments, courses, profile views, activity, bookmarks, referrals.
-- =============================================================================
SET search_path = talentra, public;

-- Shared by candidate_profile, job_requirement and offer:
-- amounts are present exactly when salary_disclosure = 'disclosed', so
-- "not disclosed" and "not applicable" are never stored as a zero salary.
CREATE FUNCTION check_salary_disclosure() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r jsonb := to_jsonb(NEW);
BEGIN
    IF ((r ->> 'salary_disclosure_id')::smallint = lookup_id('salary_disclosure', 'disclosed'))
       <> (r ->> 'salary_min' IS NOT NULL) THEN
        RAISE EXCEPTION '%: salary amounts must be present exactly when salary is disclosed', TG_TABLE_NAME
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TABLE candidate_profile (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id                 bigint NOT NULL CONSTRAINT uq_candidate_profile_user_id UNIQUE REFERENCES app_user (id),
    full_name               person_name NOT NULL,
    preferred_name          person_name,                          -- null: use full_name
    date_of_birth           date,                                 -- null: not provided (optional field)
    gender_id               smallint REFERENCES gender (id),      -- null: not provided; 'prefer_not_to_say' is a code
    headline                varchar(200),                         -- null: not written yet
    summary                 text,                                 -- free text resume summary; null: not written yet
    summary_language_id     smallint REFERENCES language (id),    -- null when summary is null or language unknown
    current_city_id         integer REFERENCES city (id),         -- null: not provided
    total_experience_months smallint NOT NULL DEFAULT 0 CHECK (total_experience_months BETWEEN 0 AND 840),
    notice_period_days      smallint CHECK (notice_period_days BETWEEN 0 AND 365),  -- null: not stated
    salary_disclosure_id    smallint NOT NULL REFERENCES salary_disclosure (id),
    salary_min              money_amount,                         -- expected salary; null unless disclosed
    salary_max              money_amount,
    currency_id             smallint REFERENCES currency (id),
    pay_period_id           smallint REFERENCES pay_period (id),
    profile_visibility_id   smallint NOT NULL REFERENCES profile_visibility (id),
    is_open_to_work         boolean NOT NULL DEFAULT true,
    profile_completion_pct  percentage NOT NULL DEFAULT 0,
    last_active_at          timestamptz,                          -- null: never active since registration
    CONSTRAINT ck_candidate_profile_salary_fields CHECK (num_nulls(salary_min, salary_max, currency_id, pay_period_id) IN (0, 4)),
    CONSTRAINT ck_candidate_profile_salary_range CHECK (salary_max >= salary_min),
    CONSTRAINT ck_candidate_profile_summary_language CHECK (summary IS NOT NULL OR summary_language_id IS NULL)
);
CALL add_standard_columns('candidate_profile', 'soft');
-- Recruiters cannot register candidates: the profile owner must create it
ALTER TABLE candidate_profile ADD CONSTRAINT ck_candidate_profile_self_registered CHECK (created_by = user_id);
CREATE TRIGGER trg_candidate_profile_salary BEFORE INSERT OR UPDATE ON candidate_profile
    FOR EACH ROW EXECUTE FUNCTION check_salary_disclosure();
CREATE INDEX idx_candidate_profile_current_city_id ON candidate_profile (current_city_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_candidate_profile_last_active_at ON candidate_profile (last_active_at) WHERE deleted_at IS NULL;

-- True when the candidate has blocked the current user or any organisation the
-- current user acts for. Used by RLS and by every write path that targets a candidate.
CREATE FUNCTION is_blocked_for(p_candidate_user_id bigint) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM block_entry b
        WHERE b.blocker_user_id = p_candidate_user_id AND b.deleted_at IS NULL
          AND (b.blocked_user_id = current_app_user_id()
               OR b.blocked_organisation_id IN (SELECT current_user_organisation_ids())))
$$;

CREATE TABLE candidate_contact (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id) ON DELETE CASCADE,
    contact_type_id      smallint NOT NULL REFERENCES contact_type (id),
    email                email_address,                         -- set for email contacts only
    phone                phone_e164,                            -- set for phone / messaging contacts only
    phone_country_id     smallint REFERENCES country (id),
    is_primary           boolean NOT NULL DEFAULT false,
    verified_at          timestamptz,                           -- null: not verified
    CONSTRAINT ck_candidate_contact_one_value CHECK (num_nonnulls(email, phone) = 1),
    CONSTRAINT ck_candidate_contact_phone_country CHECK ((phone IS NULL) = (phone_country_id IS NULL))
);
CALL add_standard_columns('candidate_contact', 'soft');
CREATE UNIQUE INDEX uq_candidate_contact_candidate_profile_id_primary
    ON candidate_contact (candidate_profile_id, contact_type_id) WHERE is_primary AND deleted_at IS NULL;

CREATE TABLE candidate_address (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id) ON DELETE CASCADE,
    address_line1        varchar(200) NOT NULL,
    address_line2        varchar(200),                    -- null: single-line address
    city_id              integer NOT NULL REFERENCES city (id),
    postal_code          varchar(12)                      -- null: country has no postal codes
);
CALL add_standard_columns('candidate_address', 'soft');

-- National identity checks: only the outcome and a provider token are stored,
-- never the raw identity number (integration boundary).
CREATE TABLE identity_verification (
    id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id                   bigint NOT NULL REFERENCES app_user (id),
    identity_document_type_id smallint NOT NULL REFERENCES identity_document_type (id),
    provider_name             varchar(60) NOT NULL,
    provider_request_id       varchar(100) NOT NULL,      -- idempotency key from the provider
    verification_token        varchar(255) NOT NULL,
    document_last4            char(4),                    -- null: provider returned no mask
    verification_status_id    smallint NOT NULL REFERENCES verification_status (id),
    verified_at               timestamptz,                -- null: pending or failed
    CONSTRAINT uq_identity_verification_provider_request UNIQUE (provider_name, provider_request_id)
);
CALL add_standard_columns('identity_verification', 'hard');

CREATE TABLE candidate_education (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id) ON DELETE CASCADE,
    qualification_id     integer NOT NULL REFERENCES qualification (id),
    institution_name     varchar(200) NOT NULL,
    specialization       varchar(150),                   -- null: none
    start_date           date NOT NULL,
    end_date             date,                           -- null: ongoing
    grade_value          numeric(6,2),                   -- null: not reported
    grade_scale          numeric(6,2),                   -- e.g. 10 for CGPA, 100 for percent
    CONSTRAINT ck_candidate_education_dates CHECK (end_date IS NULL OR end_date >= start_date),
    CONSTRAINT ck_candidate_education_grade CHECK ((grade_value IS NULL) = (grade_scale IS NULL) AND grade_value <= grade_scale)
);
CALL add_standard_columns('candidate_education', 'soft');
CREATE INDEX idx_candidate_education_candidate_profile_id ON candidate_education (candidate_profile_id);

CREATE TABLE candidate_experience (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id) ON DELETE CASCADE,
    organisation_id      bigint REFERENCES organisation (id),  -- null: employer not on the platform
    employer_name        varchar(200) NOT NULL,
    job_role_id          integer REFERENCES job_role (id),     -- null: role not mapped to master data
    title                varchar(150) NOT NULL,
    employment_type_id   smallint NOT NULL REFERENCES employment_type (id),
    start_date           date NOT NULL,
    end_date             date,                                 -- null: current job
    description          text,                                 -- free text; null: none
    CONSTRAINT ck_candidate_experience_dates CHECK (end_date IS NULL OR end_date >= start_date)
);
CALL add_standard_columns('candidate_experience', 'soft');
CREATE INDEX idx_candidate_experience_candidate_profile_id ON candidate_experience (candidate_profile_id);

CREATE TABLE candidate_skill (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id) ON DELETE CASCADE,
    skill_id             integer NOT NULL REFERENCES skill (id),
    proficiency_level_id smallint NOT NULL REFERENCES proficiency_level (id),
    years_experience     numeric(4,1) CHECK (years_experience BETWEEN 0 AND 70),  -- null: not stated
    last_used_year       smallint CHECK (last_used_year BETWEEN 1950 AND 2100),   -- null: not stated
    CONSTRAINT uq_candidate_skill_candidate_profile_id_skill_id UNIQUE (candidate_profile_id, skill_id)
);
CALL add_standard_columns('candidate_skill', 'hard');
CREATE INDEX idx_candidate_skill_skill_id ON candidate_skill (skill_id, proficiency_level_id);

CREATE TABLE candidate_language (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id) ON DELETE CASCADE,
    language_id          smallint NOT NULL REFERENCES language (id),
    proficiency_level_id smallint NOT NULL REFERENCES proficiency_level (id),
    can_read             boolean NOT NULL DEFAULT true,
    can_write            boolean NOT NULL DEFAULT true,
    can_speak            boolean NOT NULL DEFAULT true,
    CONSTRAINT uq_candidate_language_candidate_profile_id_language_id UNIQUE (candidate_profile_id, language_id)
);
CALL add_standard_columns('candidate_language', 'hard');

-- Candidate projects and gig projects (gig_worker_profile FK added in 05_gig)
CREATE TABLE profile_project (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id  bigint REFERENCES candidate_profile (id) ON DELETE CASCADE,  -- set for candidate projects
    gig_worker_profile_id bigint,                                                     -- set for gig projects
    title                 varchar(200) NOT NULL,
    role_title            varchar(150) NOT NULL,
    start_date            date NOT NULL,
    end_date              date,                       -- null: ongoing
    outcome               varchar(2000),              -- null: not described
    project_url           varchar(300),               -- null: none
    CONSTRAINT ck_profile_project_one_owner CHECK (num_nonnulls(candidate_profile_id, gig_worker_profile_id) = 1),
    CONSTRAINT ck_profile_project_dates CHECK (end_date IS NULL OR end_date >= start_date)
);
CALL add_standard_columns('profile_project', 'soft');

CREATE TABLE resume_template (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        varchar(40) NOT NULL CONSTRAINT uq_resume_template_code UNIQUE,
    ui_label_id bigint NOT NULL REFERENCES ui_label (id),
    is_active   boolean NOT NULL DEFAULT true
);
CALL add_standard_columns('resume_template', 'hard');

CREATE TABLE resume_version (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id) ON DELETE CASCADE,
    version_number       smallint NOT NULL CHECK (version_number > 0),
    resume_template_id   integer REFERENCES resume_template (id),   -- null: uploaded file, not built
    file_storage_key     varchar(300),                              -- object store key; null: built, not uploaded
    content_text         text,                                      -- extracted resume body for search; null: not parsed yet
    content_language_id  smallint REFERENCES language (id),         -- null: language not detected
    is_primary           boolean NOT NULL DEFAULT false,
    CONSTRAINT uq_resume_version_candidate_profile_id_version_number UNIQUE (candidate_profile_id, version_number),
    CONSTRAINT ck_resume_version_source CHECK (num_nonnulls(resume_template_id, file_storage_key) >= 1)
);
CALL add_standard_columns('resume_version', 'soft');
CREATE UNIQUE INDEX uq_resume_version_candidate_profile_id_primary
    ON resume_version (candidate_profile_id) WHERE is_primary AND deleted_at IS NULL;

CREATE TABLE assessment (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    skill_id       integer REFERENCES skill (id),      -- null: general aptitude test
    title          varchar(200) NOT NULL,
    pass_score_pct percentage NOT NULL,
    is_active      boolean NOT NULL DEFAULT true
);
CALL add_standard_columns('assessment', 'soft');

CREATE TABLE assessment_attempt (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    assessment_id        integer NOT NULL REFERENCES assessment (id),
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id),
    started_at           timestamptz NOT NULL,
    completed_at         timestamptz,                   -- null: in progress or abandoned
    score_pct            percentage,                    -- null until completed
    CONSTRAINT ck_assessment_attempt_completion CHECK ((completed_at IS NULL) = (score_pct IS NULL)),
    CONSTRAINT ck_assessment_attempt_dates CHECK (completed_at >= started_at)
);
CALL add_standard_columns('assessment_attempt', 'hard');
CREATE INDEX idx_assessment_attempt_candidate_profile_id ON assessment_attempt (candidate_profile_id);

CREATE TABLE course (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title          varchar(200) NOT NULL,
    provider_name  varchar(150) NOT NULL,
    duration_hours numeric(6,1) CHECK (duration_hours > 0),   -- null: self-paced, unspecified
    is_active      boolean NOT NULL DEFAULT true
);
CALL add_standard_columns('course', 'soft');

CREATE TABLE course_enrolment (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id            integer NOT NULL REFERENCES course (id),
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id),
    enrolment_status_id  smallint NOT NULL REFERENCES enrolment_status (id),
    enrolled_at          timestamptz NOT NULL DEFAULT now(),
    completed_at         timestamptz,                   -- null: not completed
    CONSTRAINT uq_course_enrolment_course_id_candidate_profile_id UNIQUE (course_id, candidate_profile_id)
);
CALL add_standard_columns('course_enrolment', 'hard');

-- Profile view history (append-only: actor, subject, timestamp)
CREATE TABLE profile_view_event (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id   bigint NOT NULL REFERENCES candidate_profile (id),
    viewer_user_id         bigint NOT NULL REFERENCES app_user (id),
    viewer_organisation_id bigint REFERENCES organisation (id),   -- null: viewer not acting for a company
    viewed_at              timestamptz NOT NULL DEFAULT now()
);
CALL add_standard_columns('profile_view_event', 'append');
CREATE INDEX idx_profile_view_event_candidate_profile_id ON profile_view_event (candidate_profile_id, viewed_at DESC);
CREATE INDEX idx_profile_view_event_viewed_at ON profile_view_event USING brin (viewed_at);

-- Candidate activity log: login, profile update, resume download ...
CREATE TABLE candidate_activity_event (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id          bigint NOT NULL REFERENCES app_user (id),
    activity_type_id smallint NOT NULL REFERENCES activity_type (id),
    occurred_at      timestamptz NOT NULL DEFAULT now(),
    details          jsonb NOT NULL DEFAULT '{}'
);
CALL add_standard_columns('candidate_activity_event', 'append');
CREATE INDEX idx_candidate_activity_event_user_id ON candidate_activity_event (user_id, occurred_at DESC);

-- Shortlist / bookmark history of employers and recruiters (job FK added in 04)
CREATE TABLE candidate_bookmark (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_user_id        bigint NOT NULL REFERENCES app_user (id),
    organisation_id      bigint NOT NULL REFERENCES organisation (id),
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id),
    job_requirement_id   bigint,                              -- null: general talent pool
    note                 varchar(500)                         -- null: no note
);
CALL add_standard_columns('candidate_bookmark', 'soft');   -- removal keeps history via deleted_at
CREATE UNIQUE INDEX uq_candidate_bookmark_owner_candidate_job
    ON candidate_bookmark (owner_user_id, candidate_profile_id, coalesce(job_requirement_id, 0)) WHERE deleted_at IS NULL;

CREATE TABLE referral (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    referrer_user_id   bigint NOT NULL REFERENCES app_user (id),
    referred_email     email_address NOT NULL,
    referred_user_id   bigint REFERENCES app_user (id),      -- null until the referred person registers
    job_requirement_id bigint,                               -- FK added in 04; null: platform referral
    referral_status_id smallint NOT NULL REFERENCES referral_status (id),
    CONSTRAINT ck_referral_not_self CHECK (referred_user_id IS DISTINCT FROM referrer_user_id)
);
CALL add_standard_columns('referral', 'hard');
CREATE UNIQUE INDEX uq_referral_referrer_email_job
    ON referral (referrer_user_id, referred_email, coalesce(job_requirement_id, 0));

-- FK indexes added by Milestone 2 validation (B5). FKs to lookup / master-data
-- tables stay unindexed on purpose: those rows are deactivated, never deleted.
CREATE INDEX idx_candidate_address_candidate_profile_id ON candidate_address (candidate_profile_id);
CREATE INDEX idx_identity_verification_user_id ON identity_verification (user_id);
CREATE INDEX idx_candidate_experience_organisation_id ON candidate_experience (organisation_id) WHERE organisation_id IS NOT NULL;
CREATE INDEX idx_profile_project_candidate_profile_id ON profile_project (candidate_profile_id) WHERE candidate_profile_id IS NOT NULL;
CREATE INDEX idx_profile_project_gig_worker_profile_id ON profile_project (gig_worker_profile_id) WHERE gig_worker_profile_id IS NOT NULL;
CREATE INDEX idx_assessment_attempt_assessment_id ON assessment_attempt (assessment_id);
CREATE INDEX idx_course_enrolment_candidate_profile_id ON course_enrolment (candidate_profile_id);
CREATE INDEX idx_profile_view_event_viewer_organisation_id ON profile_view_event (viewer_organisation_id, viewed_at DESC);
CREATE INDEX idx_profile_view_event_viewer_user_id ON profile_view_event (viewer_user_id);
CREATE INDEX idx_candidate_bookmark_candidate_profile_id ON candidate_bookmark (candidate_profile_id);
CREATE INDEX idx_candidate_bookmark_organisation_id ON candidate_bookmark (organisation_id, job_requirement_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_referral_referred_user_id ON referral (referred_user_id) WHERE referred_user_id IS NOT NULL;
CREATE INDEX idx_referral_job_requirement_id ON referral (job_requirement_id) WHERE job_requirement_id IS NOT NULL;
