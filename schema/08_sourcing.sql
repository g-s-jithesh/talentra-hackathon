-- =============================================================================
-- Talentra schema - 08 Sourcing and consultant requests (scrum master)
-- Consultants request to source for a job; the employer accepts or declines.
-- A consultant may only act on a requirement open to consultants (trigger).
-- Bulk outreach batches consume wallet credits.
-- =============================================================================
SET search_path = talentra, public;

CREATE TABLE sourcing_request (
    id                         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_requirement_id         bigint NOT NULL REFERENCES job_requirement (id),
    consultant_user_id         bigint NOT NULL REFERENCES app_user (id),
    consultant_organisation_id bigint REFERENCES organisation (id),   -- null: freelance consultant
    sourcing_request_status_id smallint NOT NULL REFERENCES sourcing_request_status (id),
    message                    varchar(2000),                         -- null: no pitch text
    decided_at                 timestamptz,                           -- null: awaiting employer
    decided_by_user_id         bigint REFERENCES app_user (id),
    decline_reason             varchar(500),                          -- null: not declined / no reason
    CONSTRAINT uq_sourcing_request_job_requirement_id_consultant UNIQUE (job_requirement_id, consultant_user_id),
    CONSTRAINT ck_sourcing_request_decision CHECK ((decided_at IS NULL) = (decided_by_user_id IS NULL))
);
CALL add_standard_columns('sourcing_request', 'hard');
CREATE INDEX idx_sourcing_request_consultant_user_id ON sourcing_request (consultant_user_id);

CREATE FUNCTION check_sourcing_request() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM job_requirement
                   WHERE id = NEW.job_requirement_id AND is_open_to_consultants AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'job requirement % is not open to consultants', NEW.job_requirement_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM user_role ur JOIN role r ON r.id = ur.role_id
                   WHERE ur.user_id = NEW.consultant_user_id AND ur.revoked_at IS NULL AND r.code = 'consultant') THEN
        RAISE EXCEPTION 'user % is not a consultant', NEW.consultant_user_id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_sourcing_request_check BEFORE INSERT OR UPDATE OF job_requirement_id, consultant_user_id
    ON sourcing_request FOR EACH ROW EXECUTE FUNCTION check_sourcing_request();

ALTER TABLE application ADD CONSTRAINT fk_application_sourcing_request_id
    FOREIGN KEY (sourcing_request_id) REFERENCES sourcing_request (id);

-- Candidates a consultant puts forward; becomes an application (source = consultant)
-- once the employer takes the candidate into the Jobs and Applications shortlist.
CREATE TABLE sourcing_shortlist_entry (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sourcing_request_id  bigint NOT NULL REFERENCES sourcing_request (id),
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id),
    note                 varchar(1000),                 -- null: none
    application_id       bigint,                        -- null until converted to an application
    job_requirement_id   bigint,
    FOREIGN KEY (application_id, job_requirement_id) REFERENCES application (id, job_requirement_id),
    CONSTRAINT uq_sourcing_shortlist_entry_request_candidate UNIQUE (sourcing_request_id, candidate_profile_id),
    CONSTRAINT ck_sourcing_shortlist_entry_application CHECK ((application_id IS NULL) = (job_requirement_id IS NULL))
);
CALL add_standard_columns('sourcing_shortlist_entry', 'soft');

CREATE FUNCTION check_shortlist_entry() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sourcing_request
                   WHERE id = NEW.sourcing_request_id
                     AND sourcing_request_status_id = lookup_id('sourcing_request_status', 'accepted')) THEN
        RAISE EXCEPTION 'sourcing request % is not accepted', NEW.sourcing_request_id USING ERRCODE = 'check_violation';
    END IF;
    IF is_blocked_for((SELECT user_id FROM candidate_profile WHERE id = NEW.candidate_profile_id)) THEN
        RAISE EXCEPTION 'candidate % has blocked this consultant', NEW.candidate_profile_id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_sourcing_shortlist_entry_check BEFORE INSERT ON sourcing_shortlist_entry
    FOR EACH ROW EXECUTE FUNCTION check_shortlist_entry();

CREATE TABLE outreach_batch (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organisation_id        bigint NOT NULL REFERENCES organisation (id),
    sender_user_id         bigint NOT NULL REFERENCES app_user (id),
    job_requirement_id     bigint REFERENCES job_requirement (id),       -- null: general outreach
    channel_id             smallint NOT NULL REFERENCES channel (id),
    message_template_key   varchar(100) NOT NULL,                        -- body lives in the template, not here
    recipient_count        integer NOT NULL DEFAULT 0 CHECK (recipient_count >= 0),
    wallet_ledger_entry_id bigint CONSTRAINT uq_outreach_batch_wallet_ledger_entry_id UNIQUE
                           REFERENCES wallet_ledger_entry (id),          -- null until credits are charged
    sent_at                timestamptz                                   -- null: draft
);
CALL add_standard_columns('outreach_batch', 'hard');

CREATE TABLE outreach_recipient (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    outreach_batch_id    bigint NOT NULL REFERENCES outreach_batch (id) ON DELETE CASCADE,
    candidate_profile_id bigint NOT NULL REFERENCES candidate_profile (id),
    delivery_status_id   smallint NOT NULL REFERENCES delivery_status (id),
    delivered_at         timestamptz,              -- null: not delivered
    responded_at         timestamptz,              -- null: no response
    CONSTRAINT uq_outreach_recipient_batch_candidate UNIQUE (outreach_batch_id, candidate_profile_id)
);
CALL add_standard_columns('outreach_recipient', 'hard');
CREATE INDEX idx_outreach_recipient_candidate_profile_id ON outreach_recipient (candidate_profile_id);

CREATE FUNCTION check_outreach_recipient() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF is_blocked_for((SELECT user_id FROM candidate_profile WHERE id = NEW.candidate_profile_id)) THEN
        RAISE EXCEPTION 'candidate % has blocked the sender', NEW.candidate_profile_id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_outreach_recipient_check BEFORE INSERT ON outreach_recipient
    FOR EACH ROW EXECUTE FUNCTION check_outreach_recipient();
