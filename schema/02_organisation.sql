-- =============================================================================
-- Talentra schema - 02 Organisation and account (scrum master)
-- Employers, clients, consultancies, hierarchy, locations, tax identifiers,
-- recruiter mapping (effective-dated) and account administrators.
-- =============================================================================
SET search_path = talentra, public;

CREATE TABLE organisation (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_organisation_id bigint REFERENCES organisation (id),   -- null: top of its hierarchy
    organisation_type_id   smallint NOT NULL REFERENCES organisation_type (id),
    legal_name             varchar(200) NOT NULL,
    display_name           varchar(200) NOT NULL,
    industry_id            integer REFERENCES industry (id),       -- null: not classified at registration
    website_url            varchar(300),                           -- null: none given
    verification_status_id smallint NOT NULL REFERENCES verification_status (id),
    account_status_id      smallint NOT NULL REFERENCES account_status (id),
    CONSTRAINT ck_organisation_not_own_parent CHECK (parent_organisation_id <> id)
);
CALL add_standard_columns('organisation', 'soft');
CREATE INDEX idx_organisation_parent_organisation_id ON organisation (parent_organisation_id);

-- Deeper hierarchy cycles (A -> B -> A) are rejected here
CREATE FUNCTION check_organisation_cycle() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.parent_organisation_id IS NOT NULL AND EXISTS (
        WITH RECURSIVE up AS (
            SELECT id, parent_organisation_id FROM organisation WHERE id = NEW.parent_organisation_id
            UNION ALL
            SELECT o.id, o.parent_organisation_id FROM organisation o JOIN up ON o.id = up.parent_organisation_id)
        SELECT 1 FROM up WHERE id = NEW.id) THEN
        RAISE EXCEPTION 'organisation hierarchy cycle via %', NEW.parent_organisation_id;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_organisation_cycle BEFORE INSERT OR UPDATE OF parent_organisation_id ON organisation
    FOR EACH ROW EXECUTE FUNCTION check_organisation_cycle();

CREATE TABLE organisation_location (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organisation_id   bigint NOT NULL REFERENCES organisation (id) ON DELETE CASCADE,
    address_line1     varchar(200) NOT NULL,
    address_line2     varchar(200),                    -- null: single-line address
    city_id           integer NOT NULL REFERENCES city (id),
    postal_code       varchar(12),                     -- null: country has no postal codes
    latitude          latitude,                        -- null: not geocoded (optional service)
    longitude         longitude,
    coordinate_source varchar(40),
    place_reference   varchar(100),                    -- external map place id; null: not geocoded
    is_headquarters   boolean NOT NULL DEFAULT false,
    CONSTRAINT ck_organisation_location_coordinates CHECK (num_nulls(latitude, longitude, coordinate_source) IN (0, 3))
);
CALL add_standard_columns('organisation_location', 'soft');
CREATE UNIQUE INDEX uq_organisation_location_organisation_id_hq
    ON organisation_location (organisation_id) WHERE is_headquarters AND deleted_at IS NULL;

-- Tax / registration identifiers: Sensitive. Encrypted by the access layer (KMS);
-- the hash supports uniqueness and lookup without decrypting.
CREATE TABLE organisation_tax_identifier (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organisation_id        bigint NOT NULL REFERENCES organisation (id) ON DELETE CASCADE,
    tax_identifier_type_id smallint NOT NULL REFERENCES tax_identifier_type (id),
    country_id             smallint NOT NULL REFERENCES country (id),
    identifier_hash        bytea NOT NULL,             -- HMAC-SHA256 of the normalised identifier
    identifier_ciphertext  bytea NOT NULL,
    identifier_masked      varchar(20) NOT NULL,        -- e.g. XXXXXXXX1Z5
    verification_status_id smallint NOT NULL REFERENCES verification_status (id),
    verified_at            timestamptz,                 -- null: not verified yet
    verification_reference varchar(100),                -- external check id; null: not verified yet
    CONSTRAINT uq_organisation_tax_identifier_type_country_hash
        UNIQUE (tax_identifier_type_id, country_id, identifier_hash)
);
CALL add_standard_columns('organisation_tax_identifier', 'hard');
CREATE INDEX idx_organisation_tax_identifier_organisation_id ON organisation_tax_identifier (organisation_id);

-- Recruiter mapping is effective-dated: a recruiter belongs to one company at a time.
CREATE TABLE organisation_recruiter (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organisation_id bigint NOT NULL REFERENCES organisation (id),
    user_id         bigint NOT NULL REFERENCES app_user (id),
    valid_from      date NOT NULL DEFAULT current_date,
    valid_to        date,                               -- null: mapping still active
    CONSTRAINT ck_organisation_recruiter_period CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT ex_organisation_recruiter_user_id_period
        EXCLUDE USING gist (user_id WITH =, daterange(valid_from, valid_to, '[)') WITH &&)
);
CALL add_standard_columns('organisation_recruiter', 'hard');
CREATE INDEX idx_organisation_recruiter_organisation_id ON organisation_recruiter (organisation_id);

CREATE TABLE account_administrator (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organisation_id bigint NOT NULL REFERENCES organisation (id),
    user_id         bigint NOT NULL REFERENCES app_user (id),
    valid_from      date NOT NULL DEFAULT current_date,
    valid_to        date,                               -- null: still an administrator
    CONSTRAINT ck_account_administrator_period CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT ex_account_administrator_organisation_id_user_id_period
        EXCLUDE USING gist (organisation_id WITH =, user_id WITH =, daterange(valid_from, valid_to, '[)') WITH &&)
);
CALL add_standard_columns('account_administrator', 'hard');

-- Organisations the current user acts for today (recruiter or account admin)
CREATE FUNCTION current_user_organisation_ids() RETURNS SETOF bigint
LANGUAGE sql STABLE AS $$
    SELECT organisation_id FROM organisation_recruiter
    WHERE user_id = current_app_user_id()
      AND current_date >= valid_from AND (valid_to IS NULL OR current_date < valid_to)
    UNION
    SELECT organisation_id FROM account_administrator
    WHERE user_id = current_app_user_id()
      AND current_date >= valid_from AND (valid_to IS NULL OR current_date < valid_to)
$$;

-- Deferred FKs from 01
ALTER TABLE block_entry ADD CONSTRAINT fk_block_entry_blocked_organisation_id
    FOREIGN KEY (blocked_organisation_id) REFERENCES organisation (id);
ALTER TABLE audit_event ADD CONSTRAINT fk_audit_event_organisation_id
    FOREIGN KEY (organisation_id) REFERENCES organisation (id);
