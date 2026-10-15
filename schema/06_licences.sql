-- =============================================================================
-- Talentra schema - 06 Licences, seats, devices and sessions (Member A)
-- Rule group 9: limits are enforced in the database under concurrency by
-- locking the parent row (licence for seats, licence_seat for sessions).
-- Every user holds a seat: candidates get one on a Free-plan licence at sign-up.
-- =============================================================================
SET search_path = talentra, public;

CREATE TABLE licence (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organisation_id      bigint REFERENCES organisation (id),     -- set for company licences
    owner_user_id        bigint REFERENCES app_user (id),         -- set for individual licences
    max_users            integer NOT NULL CHECK (max_users > 0),
    max_devices_per_user integer NOT NULL CHECK (max_devices_per_user > 0),
    is_active            boolean NOT NULL DEFAULT true,
    CONSTRAINT ck_licence_one_owner CHECK (num_nonnulls(organisation_id, owner_user_id) = 1)
);
CALL add_standard_columns('licence', 'hard');
CREATE INDEX idx_licence_organisation_id ON licence (organisation_id);

CREATE TABLE licence_seat (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    licence_id  bigint NOT NULL REFERENCES licence (id),
    user_id     bigint NOT NULL REFERENCES app_user (id),
    assigned_at timestamptz NOT NULL DEFAULT now(),
    released_at timestamptz,                     -- null: seat in use
    CONSTRAINT ck_licence_seat_period CHECK (released_at IS NULL OR released_at >= assigned_at)
);
CALL add_standard_columns('licence_seat', 'hard');
CREATE UNIQUE INDEX uq_licence_seat_user_id ON licence_seat (user_id) WHERE released_at IS NULL;  -- one live seat per user
CREATE INDEX idx_licence_seat_licence_id ON licence_seat (licence_id) WHERE released_at IS NULL;

-- Seat limit: lock the licence row, then count live seats
CREATE FUNCTION enforce_seat_limit() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_max integer; v_used integer;
BEGIN
    IF NEW.released_at IS NOT NULL THEN RETURN NEW; END IF;
    SELECT max_users INTO v_max FROM licence WHERE id = NEW.licence_id AND is_active FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'licence % is not active', NEW.licence_id; END IF;
    SELECT count(*) INTO v_used FROM licence_seat
    WHERE licence_id = NEW.licence_id AND released_at IS NULL AND id IS DISTINCT FROM NEW.id;
    IF v_used >= v_max THEN
        RAISE EXCEPTION 'licence % has no free seat (% of % used)', NEW.licence_id, v_used, v_max
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_licence_seat_limit BEFORE INSERT OR UPDATE OF released_at, licence_id ON licence_seat
    FOR EACH ROW EXECUTE FUNCTION enforce_seat_limit();

CREATE TABLE user_device (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id                 bigint NOT NULL REFERENCES app_user (id),
    device_fingerprint_hash bytea NOT NULL,                -- hash of the client device id, never the raw id
    device_type_id          smallint NOT NULL REFERENCES device_type (id),
    display_name            varchar(100),                  -- e.g. "Chrome on Windows"; null: unknown agent
    first_seen_at           timestamptz NOT NULL DEFAULT now(),
    revoked_at              timestamptz,                   -- null: device trusted
    revoked_by_user_id      bigint REFERENCES app_user (id),
    CONSTRAINT ck_user_device_revocation CHECK ((revoked_at IS NULL) = (revoked_by_user_id IS NULL))
);
CALL add_standard_columns('user_device', 'hard');
CREATE UNIQUE INDEX uq_user_device_user_id_fingerprint ON user_device (user_id, device_fingerprint_hash) WHERE revoked_at IS NULL;

CREATE TABLE user_session (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id               bigint NOT NULL REFERENCES app_user (id),
    user_device_id        bigint NOT NULL REFERENCES user_device (id),
    licence_seat_id       bigint NOT NULL REFERENCES licence_seat (id),
    token_hash            bytea NOT NULL CONSTRAINT uq_user_session_token_hash UNIQUE,  -- SHA-256 of the session token
    ip_address            inet,                            -- null: not captured
    started_at            timestamptz NOT NULL DEFAULT now(),
    last_activity_at      timestamptz NOT NULL DEFAULT now(),
    expires_at            timestamptz NOT NULL,
    ended_at              timestamptz,                     -- null: not ended (still counts until expires_at)
    session_end_reason_id smallint REFERENCES session_end_reason (id),
    CONSTRAINT ck_user_session_end CHECK ((ended_at IS NULL) = (session_end_reason_id IS NULL)),
    CONSTRAINT ck_user_session_expiry CHECK (expires_at > started_at)
);
CALL add_standard_columns('user_session', 'hard');
-- Active session = ended_at IS NULL AND expires_at > now(); expired / revoked sessions don't count
CREATE INDEX idx_user_session_user_id_active ON user_session (user_id, expires_at) WHERE ended_at IS NULL;

-- Backstop for any insert path: lock the seat, count other devices with a live session
CREATE FUNCTION enforce_device_limit() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_max integer; v_devices integer;
BEGIN
    SELECT l.max_devices_per_user INTO v_max
    FROM licence_seat s JOIN licence l ON l.id = s.licence_id
    WHERE s.id = NEW.licence_seat_id AND s.user_id = NEW.user_id AND s.released_at IS NULL
    FOR UPDATE OF s;
    IF NOT FOUND THEN RAISE EXCEPTION 'user % has no live seat %', NEW.user_id, NEW.licence_seat_id; END IF;
    SELECT count(DISTINCT user_device_id) INTO v_devices FROM user_session
    WHERE user_id = NEW.user_id AND ended_at IS NULL AND expires_at > now()
      AND user_device_id <> NEW.user_device_id;
    IF v_devices >= v_max THEN
        RAISE EXCEPTION 'device limit % reached for user %', v_max, NEW.user_id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_user_session_device_limit BEFORE INSERT ON user_session
    FOR EACH ROW EXECUTE FUNCTION enforce_device_limit();

-- Login history (append-only), including failures for unknown emails
CREATE TABLE login_attempt (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         bigint REFERENCES app_user (id),        -- null: email not registered
    email_attempted email_address NOT NULL,
    user_device_id  bigint REFERENCES user_device (id),     -- null: failed before device registration
    is_success      boolean NOT NULL,
    failure_reason  varchar(60),                            -- e.g. bad_password, device_limit; null on success
    ip_address      inet,                                   -- null: not captured
    attempted_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_login_attempt_reason CHECK (is_success = (failure_reason IS NULL))
);
CALL make_append_only('login_attempt');
CREATE INDEX idx_login_attempt_user_id ON login_attempt (user_id, attempted_at DESC);

-- Login entry point. Returns the new session id, or NULL when the device limit is
-- reached; in that case the refused attempt is kept in login_attempt and audit_event
-- (a RAISE would roll those rows back).
CREATE FUNCTION start_session(p_user_id bigint, p_device_fingerprint_hash bytea, p_device_type_code text,
                              p_token_hash bytea, p_ip inet DEFAULT NULL,
                              p_ttl interval DEFAULT interval '12 hours')
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = talentra, public AS $$
DECLARE
    v_seat_id   bigint;
    v_max       integer;
    v_device_id bigint;
    v_devices   integer;
    v_email     text;
    v_session   bigint;
BEGIN
    PERFORM set_config('app.user_id', p_user_id::text, true);
    SELECT email INTO v_email FROM app_user WHERE id = p_user_id AND deleted_at IS NULL;

    -- Serialise concurrent logins of the same user on the seat row
    SELECT s.id, l.max_devices_per_user INTO v_seat_id, v_max
    FROM licence_seat s JOIN licence l ON l.id = s.licence_id
    WHERE s.user_id = p_user_id AND s.released_at IS NULL AND l.is_active
    FOR UPDATE OF s;
    IF NOT FOUND THEN RAISE EXCEPTION 'user % has no live licence seat', p_user_id; END IF;

    SELECT id INTO v_device_id FROM user_device
    WHERE user_id = p_user_id AND device_fingerprint_hash = p_device_fingerprint_hash AND revoked_at IS NULL;
    IF v_device_id IS NULL THEN
        INSERT INTO user_device (user_id, device_fingerprint_hash, device_type_id)
        VALUES (p_user_id, p_device_fingerprint_hash, lookup_id('device_type', p_device_type_code))
        RETURNING id INTO v_device_id;
    END IF;

    SELECT count(DISTINCT user_device_id) INTO v_devices FROM user_session
    WHERE user_id = p_user_id AND ended_at IS NULL AND expires_at > now() AND user_device_id <> v_device_id;

    IF v_devices >= v_max THEN
        INSERT INTO login_attempt (user_id, email_attempted, user_device_id, is_success, failure_reason, ip_address)
        VALUES (p_user_id, v_email, v_device_id, false, 'device_limit', p_ip);
        PERFORM write_audit('session.device_limit_refused', 'user_session', NULL,
                            jsonb_build_object('max_devices', v_max, 'active_devices', v_devices, 'device_id', v_device_id));
        RETURN NULL;
    END IF;

    INSERT INTO user_session (user_id, user_device_id, licence_seat_id, token_hash, ip_address, expires_at)
    VALUES (p_user_id, v_device_id, v_seat_id, p_token_hash, p_ip, now() + p_ttl)
    RETURNING id INTO v_session;
    INSERT INTO login_attempt (user_id, email_attempted, user_device_id, is_success, ip_address)
    VALUES (p_user_id, v_email, v_device_id, true, p_ip);
    UPDATE app_user SET last_login_at = now() WHERE id = p_user_id;
    RETURN v_session;
END $$;

-- Logout / expiry / revocation. Revocation is audited.
CREATE FUNCTION end_session(p_session_id bigint, p_reason_code text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = talentra, public AS $$
BEGIN
    UPDATE user_session SET ended_at = now(), session_end_reason_id = lookup_id('session_end_reason', p_reason_code)
    WHERE id = p_session_id AND ended_at IS NULL;
    IF p_reason_code = 'revoked' THEN
        PERFORM write_audit('session.revoke', 'user_session', p_session_id);
    END IF;
END $$;

CREATE FUNCTION revoke_device(p_user_device_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = talentra, public AS $$
BEGIN
    UPDATE user_device SET revoked_at = now(), revoked_by_user_id = current_app_user_id()
    WHERE id = p_user_device_id AND revoked_at IS NULL;
    UPDATE user_session SET ended_at = now(), session_end_reason_id = lookup_id('session_end_reason', 'revoked')
    WHERE user_device_id = p_user_device_id AND ended_at IS NULL;
    PERFORM write_audit('device.revoke', 'user_device', p_user_device_id);
END $$;
