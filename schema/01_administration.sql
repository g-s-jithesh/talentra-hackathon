-- =============================================================================
-- Talentra schema - 01 Administration (Member A)
-- Users, credentials, roles, permissions, consent, blocking, audit trail, errors.
-- Device-bound sessions and login history live in 06_licences.sql.
-- =============================================================================
SET search_path = talentra, public;

CREATE TABLE user_credential (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id              bigint NOT NULL CONSTRAINT uq_user_credential_user_id UNIQUE
                         REFERENCES app_user (id) ON DELETE CASCADE,
    password_hash        varchar(255) NOT NULL,          -- argon2id PHC string, never plaintext
    password_changed_at  timestamptz NOT NULL DEFAULT now(),
    failed_attempt_count smallint NOT NULL DEFAULT 0 CHECK (failed_attempt_count >= 0),
    locked_until         timestamptz                     -- null: not locked
);
CALL add_standard_columns('user_credential', 'hard');

CREATE TABLE role (
    id                     smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code                   varchar(40) NOT NULL CONSTRAINT uq_role_code UNIQUE,
    ui_label_id            bigint NOT NULL REFERENCES ui_label (id),
    is_organisation_scoped boolean NOT NULL DEFAULT false  -- recruiter / account admin act inside one organisation
);
CALL add_standard_columns('role', 'hard');

CREATE TABLE permission (
    id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        varchar(80) NOT NULL CONSTRAINT uq_permission_code UNIQUE,   -- e.g. job_requirement.publish
    ui_label_id bigint NOT NULL REFERENCES ui_label (id)
);
CALL add_standard_columns('permission', 'hard');

CREATE TABLE role_permission (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_id       smallint NOT NULL REFERENCES role (id) ON DELETE CASCADE,
    permission_id smallint NOT NULL REFERENCES permission (id) ON DELETE CASCADE,
    CONSTRAINT uq_role_permission_role_id_permission_id UNIQUE (role_id, permission_id)
);
CALL add_standard_columns('role_permission', 'hard');

CREATE TABLE user_role (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    bigint NOT NULL REFERENCES app_user (id),
    role_id    smallint NOT NULL REFERENCES role (id),
    granted_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,                                -- null: role currently held
    CONSTRAINT ck_user_role_period CHECK (revoked_at IS NULL OR revoked_at >= granted_at)
);
CALL add_standard_columns('user_role', 'hard');
CREATE UNIQUE INDEX uq_user_role_user_id_role_id ON user_role (user_id, role_id) WHERE revoked_at IS NULL;

CREATE FUNCTION has_role(p_role_code text) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM user_role ur JOIN role r ON r.id = ur.role_id
        WHERE ur.user_id = current_app_user_id() AND ur.revoked_at IS NULL AND r.code = p_role_code)
$$;

-- Consent: every grant or withdrawal is a new row (append-only history)
CREATE TABLE consent_record (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id            bigint NOT NULL REFERENCES app_user (id),
    consent_purpose_id smallint NOT NULL REFERENCES consent_purpose (id),
    is_granted         boolean NOT NULL,
    policy_version     varchar(20) NOT NULL,
    source_ip          inet                                -- null: recorded by a back-office process
);
CALL add_standard_columns('consent_record', 'append');
CREATE INDEX idx_consent_record_user_id ON consent_record (user_id, consent_purpose_id, created_at DESC);

-- A user (normally a candidate) blocks another user or a whole organisation.
-- Platform-level blocking of users/companies by admins is account_status = 'blocked'.
CREATE TABLE block_entry (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    blocker_user_id         bigint NOT NULL REFERENCES app_user (id),
    blocked_user_id         bigint REFERENCES app_user (id),     -- null when an organisation is blocked
    blocked_organisation_id bigint,                              -- FK added in 02; null when a user is blocked
    reason                  varchar(500),                        -- null: no reason given
    CONSTRAINT ck_block_entry_one_target CHECK (num_nonnulls(blocked_user_id, blocked_organisation_id) = 1),
    CONSTRAINT ck_block_entry_not_self CHECK (blocked_user_id IS DISTINCT FROM blocker_user_id)
);
CALL add_standard_columns('block_entry', 'soft');               -- unblock = soft delete, history kept
CREATE UNIQUE INDEX uq_block_entry_blocker_user_id_blocked_user_id
    ON block_entry (blocker_user_id, blocked_user_id) WHERE deleted_at IS NULL AND blocked_user_id IS NOT NULL;
CREATE UNIQUE INDEX uq_block_entry_blocker_user_id_blocked_organisation_id
    ON block_entry (blocker_user_id, blocked_organisation_id) WHERE deleted_at IS NULL AND blocked_organisation_id IS NOT NULL;
CREATE INDEX idx_block_entry_blocked_user_id ON block_entry (blocked_user_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_block_entry_blocked_organisation_id ON block_entry (blocked_organisation_id) WHERE deleted_at IS NULL;

-- Audit trail: append-only, monthly partitions. Not stamped with created_by
-- because anonymous events (failed login for an unknown email) have no actor.
CREATE TABLE audit_event (
    id              bigint GENERATED ALWAYS AS IDENTITY,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    actor_user_id   bigint REFERENCES app_user (id),         -- null: anonymous or system event
    organisation_id bigint,                                  -- FK added in 02; null: not organisation-scoped
    action_code     varchar(60) NOT NULL,                    -- e.g. profile.download, session.revoke
    entity_table    varchar(63) NOT NULL,
    entity_id       bigint,                                  -- null: action not tied to one row
    ip_address      inet,                                    -- null: server-side action
    details         jsonb NOT NULL DEFAULT '{}',
    PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);
CALL create_monthly_partitions('audit_event', DATE '2026-10-01', 6);
CALL make_append_only('audit_event');
CREATE INDEX idx_audit_event_actor_user_id ON audit_event (actor_user_id, occurred_at);
CREATE INDEX idx_audit_event_entity_table_entity_id ON audit_event (entity_table, entity_id);

CREATE FUNCTION write_audit(p_action text, p_table text, p_entity_id bigint,
                            p_details jsonb DEFAULT '{}', p_organisation_id bigint DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO audit_event (actor_user_id, organisation_id, action_code, entity_table, entity_id, details)
    VALUES (current_app_user_id(), p_organisation_id, p_action, p_table, p_entity_id, p_details)
$$;

CREATE TABLE system_error (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at       timestamptz NOT NULL DEFAULT now(),
    error_severity_id smallint NOT NULL REFERENCES error_severity (id),
    source_component  varchar(100) NOT NULL,
    error_code        varchar(40) NOT NULL,
    message           varchar(2000) NOT NULL,
    request_id        uuid,                                   -- null: not raised inside a request
    user_id           bigint REFERENCES app_user (id),        -- null: no signed-in user
    stack_trace       text                                    -- unbounded: raw diagnostic text
);
CALL make_append_only('system_error');
CREATE INDEX idx_system_error_occurred_at ON system_error USING brin (occurred_at);
