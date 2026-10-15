-- =============================================================================
-- Talentra schema - 07 Subscriptions, wallet, payments, download history (Member B)
-- Rule group 10: ledgers are append-only; corrections are reversing entries.
-- Subscription periods cannot overlap per licence (EXCLUDE constraint).
-- Card / bank data never enters the database: only gateway references.
-- =============================================================================
SET search_path = talentra, public;

CREATE TABLE subscription_plan (
    id                   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code                 varchar(40) NOT NULL CONSTRAINT uq_subscription_plan_code UNIQUE,
    ui_label_id          bigint NOT NULL REFERENCES ui_label (id),
    price                money_amount NOT NULL,
    currency_id          smallint NOT NULL REFERENCES currency (id),
    billing_period_id    smallint NOT NULL REFERENCES billing_period (id),
    max_users            integer NOT NULL CHECK (max_users > 0),
    max_devices_per_user integer NOT NULL CHECK (max_devices_per_user > 0),
    included_credits     credit_count NOT NULL DEFAULT 0 CHECK (included_credits >= 0),
    is_active            boolean NOT NULL DEFAULT true
);
CALL add_standard_columns('subscription_plan', 'hard');

CREATE TABLE plan_entitlement (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscription_plan_id smallint NOT NULL REFERENCES subscription_plan (id) ON DELETE CASCADE,
    entitlement_type_id  smallint NOT NULL REFERENCES entitlement_type (id),  -- job_posting, profile_download ...
    quantity             integer NOT NULL CHECK (quantity >= 0),               -- per billing period
    CONSTRAINT uq_plan_entitlement_plan_id_type_id UNIQUE (subscription_plan_id, entitlement_type_id)
);
CALL add_standard_columns('plan_entitlement', 'hard');

CREATE TABLE subscription (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    licence_id             bigint NOT NULL REFERENCES licence (id),
    subscription_plan_id   smallint NOT NULL REFERENCES subscription_plan (id),
    subscription_status_id smallint NOT NULL REFERENCES subscription_status (id),
    auto_renew             boolean NOT NULL DEFAULT true,
    cancelled_at           timestamptz,               -- null: not cancelled
    cancellation_reason    varchar(500),              -- null: not cancelled or no reason given
    CONSTRAINT uq_subscription_id_licence_id UNIQUE (id, licence_id),
    CONSTRAINT ck_subscription_cancellation CHECK (cancelled_at IS NOT NULL OR cancellation_reason IS NULL)
);
CALL add_standard_columns('subscription', 'hard');
CREATE INDEX idx_subscription_licence_id ON subscription (licence_id);

-- Wallet balance is a cached sum of the ledger, changed only by post_wallet_entry()
CREATE TABLE wallet (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organisation_id bigint CONSTRAINT uq_wallet_organisation_id UNIQUE REFERENCES organisation (id),  -- company wallet
    owner_user_id   bigint CONSTRAINT uq_wallet_owner_user_id UNIQUE REFERENCES app_user (id),        -- individual wallet
    balance         credit_count NOT NULL DEFAULT 0 CHECK (balance >= 0),
    CONSTRAINT ck_wallet_one_owner CHECK (num_nonnulls(organisation_id, owner_user_id) = 1)
);
CALL add_standard_columns('wallet', 'hard');

CREATE TABLE payment_order (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wallet_id               bigint REFERENCES wallet (id),           -- set for wallet recharges
    subscription_id         bigint REFERENCES subscription (id),     -- set for subscription purchase / renewal
    amount                  money_amount NOT NULL CHECK (amount > 0),
    currency_id             smallint NOT NULL REFERENCES currency (id),
    credits_to_add          credit_count CHECK (credits_to_add > 0), -- recharges only
    payment_status_id       smallint NOT NULL REFERENCES payment_status (id),
    gateway_name            varchar(40) NOT NULL,
    gateway_order_reference varchar(100),                            -- null until the gateway order exists
    idempotency_key         uuid NOT NULL CONSTRAINT uq_payment_order_idempotency_key UNIQUE,
    paid_at                 timestamptz,                             -- null: not captured
    CONSTRAINT uq_payment_order_gateway_order_reference UNIQUE (gateway_name, gateway_order_reference),
    CONSTRAINT ck_payment_order_purpose CHECK (num_nonnulls(wallet_id, subscription_id) = 1),
    CONSTRAINT ck_payment_order_credits CHECK ((wallet_id IS NULL) = (credits_to_add IS NULL))
);
CALL add_standard_columns('payment_order', 'hard');

-- Gateway webhooks (append-only); gateway_event_id makes redelivery idempotent
CREATE TABLE payment_event (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_order_id  bigint NOT NULL REFERENCES payment_order (id),
    gateway_event_id  varchar(100) NOT NULL CONSTRAINT uq_payment_event_gateway_event_id UNIQUE,
    payment_status_id smallint NOT NULL REFERENCES payment_status (id),
    received_at       timestamptz NOT NULL DEFAULT now(),
    payload_summary   jsonb NOT NULL DEFAULT '{}'    -- status fields only; no card or bank data
);
CALL add_standard_columns('payment_event', 'append');
CREATE INDEX idx_payment_event_payment_order_id ON payment_event (payment_order_id);

CREATE TABLE subscription_period (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscription_id  bigint NOT NULL,
    licence_id       bigint NOT NULL,                        -- copied from subscription for the exclusion rule
    period_start     date NOT NULL,
    period_end       date NOT NULL,                          -- exclusive
    is_renewal       boolean NOT NULL DEFAULT false,
    payment_order_id bigint REFERENCES payment_order (id),   -- null: free or complimentary period
    FOREIGN KEY (subscription_id, licence_id) REFERENCES subscription (id, licence_id),
    CONSTRAINT ck_subscription_period_dates CHECK (period_end > period_start),
    CONSTRAINT ex_subscription_period_licence_id_period
        EXCLUDE USING gist (licence_id WITH =, daterange(period_start, period_end, '[)') WITH &&)
);
CALL add_standard_columns('subscription_period', 'hard');

CREATE TABLE wallet_ledger_entry (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wallet_id            bigint NOT NULL REFERENCES wallet (id),
    ledger_entry_type_id smallint NOT NULL REFERENCES ledger_entry_type (id),   -- recharge, consumption, refund, reversal
    credit_purpose_id    smallint REFERENCES credit_purpose (id),               -- consumption only: posting, download, outreach
    credits_delta        credit_count NOT NULL CHECK (credits_delta <> 0),
    balance_after        credit_count NOT NULL CHECK (balance_after >= 0),
    payment_order_id     bigint REFERENCES payment_order (id),                  -- null: not money-backed
    reverses_entry_id    bigint CONSTRAINT uq_wallet_ledger_entry_reverses_entry_id UNIQUE
                         REFERENCES wallet_ledger_entry (id),                   -- null: not a correction
    description          varchar(300)                                           -- null: none
);
CALL add_standard_columns('wallet_ledger_entry', 'append');
CREATE INDEX idx_wallet_ledger_entry_wallet_id ON wallet_ledger_entry (wallet_id, created_at DESC);

-- The only way to move credits: lock wallet, check balance, append entry, update cache
CREATE FUNCTION post_wallet_entry(p_wallet_id bigint, p_credits_delta integer, p_entry_type_code text,
                                  p_credit_purpose_code text DEFAULT NULL, p_payment_order_id bigint DEFAULT NULL,
                                  p_reverses_entry_id bigint DEFAULT NULL, p_description text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = talentra, public AS $$
DECLARE v_balance integer; v_entry bigint;
BEGIN
    SELECT balance + p_credits_delta INTO v_balance FROM wallet WHERE id = p_wallet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'wallet % not found', p_wallet_id; END IF;
    IF v_balance < 0 THEN
        RAISE EXCEPTION 'insufficient credits in wallet %', p_wallet_id USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO wallet_ledger_entry (wallet_id, ledger_entry_type_id, credit_purpose_id, credits_delta, balance_after,
                                     payment_order_id, reverses_entry_id, description)
    VALUES (p_wallet_id, lookup_id('ledger_entry_type', p_entry_type_code),
            CASE WHEN p_credit_purpose_code IS NOT NULL THEN lookup_id('credit_purpose', p_credit_purpose_code) END,
            p_credits_delta, v_balance, p_payment_order_id, p_reverses_entry_id, p_description)
    RETURNING id INTO v_entry;
    UPDATE wallet SET balance = v_balance WHERE id = p_wallet_id;
    RETURN v_entry;
END $$;

CREATE TABLE invoice (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_order_id bigint NOT NULL CONSTRAINT uq_invoice_payment_order_id UNIQUE REFERENCES payment_order (id),
    invoice_number   varchar(30) NOT NULL CONSTRAINT uq_invoice_invoice_number UNIQUE,
    invoice_status_id smallint NOT NULL REFERENCES invoice_status (id),
    issued_at        timestamptz NOT NULL DEFAULT now(),
    net_amount       money_amount NOT NULL,
    tax_amount       money_amount NOT NULL,
    gross_amount     money_amount NOT NULL,
    currency_id      smallint NOT NULL REFERENCES currency (id),
    CONSTRAINT ck_invoice_totals CHECK (gross_amount = net_amount + tax_amount)
);
CALL add_standard_columns('invoice', 'hard');

CREATE TABLE refund (
    id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_order_id         bigint NOT NULL REFERENCES payment_order (id),
    amount                   money_amount NOT NULL CHECK (amount > 0),
    currency_id              smallint NOT NULL REFERENCES currency (id),
    refund_status_id         smallint NOT NULL REFERENCES refund_status (id),
    gateway_refund_reference varchar(100),                 -- null until the gateway accepts it
    reason                   varchar(500) NOT NULL,
    processed_at             timestamptz,                  -- null: not processed yet
    CONSTRAINT uq_refund_gateway_refund_reference UNIQUE (gateway_refund_reference)
);
CALL add_standard_columns('refund', 'hard');

-- Refunds on an order can never exceed what was paid
CREATE FUNCTION check_refund_total() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_paid numeric; v_refunded numeric;
BEGIN
    SELECT amount INTO v_paid FROM payment_order WHERE id = NEW.payment_order_id FOR UPDATE;
    SELECT coalesce(sum(amount), 0) INTO v_refunded FROM refund
    WHERE payment_order_id = NEW.payment_order_id AND id IS DISTINCT FROM NEW.id;
    IF v_refunded + NEW.amount > v_paid THEN
        RAISE EXCEPTION 'refunds (%) exceed paid amount (%)', v_refunded + NEW.amount, v_paid
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_refund_total BEFORE INSERT OR UPDATE OF amount ON refund
    FOR EACH ROW EXECUTE FUNCTION check_refund_total();

-- Profile download history: actor, subject, timestamp and the credit deduction
CREATE TABLE profile_download (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    candidate_profile_id   bigint NOT NULL REFERENCES candidate_profile (id),
    downloader_user_id     bigint NOT NULL REFERENCES app_user (id),
    organisation_id        bigint NOT NULL REFERENCES organisation (id),
    wallet_ledger_entry_id bigint NOT NULL CONSTRAINT uq_profile_download_wallet_ledger_entry_id UNIQUE
                           REFERENCES wallet_ledger_entry (id),
    downloaded_at          timestamptz NOT NULL DEFAULT now()
);
CALL add_standard_columns('profile_download', 'append');
CREATE INDEX idx_profile_download_candidate_profile_id ON profile_download (candidate_profile_id, downloaded_at DESC);
CREATE INDEX idx_profile_download_organisation_id ON profile_download (organisation_id, downloaded_at DESC);

-- Download = credit deduction + history row + audit, in one transaction
CREATE FUNCTION record_profile_download(p_candidate_profile_id bigint, p_organisation_id bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = talentra, public AS $$
DECLARE v_wallet bigint; v_entry bigint; v_download bigint; v_candidate_user bigint;
BEGIN
    IF p_organisation_id NOT IN (SELECT current_user_organisation_ids()) THEN
        RAISE EXCEPTION 'user does not act for organisation %', p_organisation_id USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT user_id INTO v_candidate_user FROM candidate_profile WHERE id = p_candidate_profile_id AND deleted_at IS NULL;
    IF v_candidate_user IS NULL OR is_blocked_for(v_candidate_user) THEN
        RAISE EXCEPTION 'candidate % not available', p_candidate_profile_id USING ERRCODE = 'insufficient_privilege';
    END IF;
    SELECT id INTO v_wallet FROM wallet WHERE organisation_id = p_organisation_id;
    v_entry := post_wallet_entry(v_wallet, -1, 'consumption', 'profile_download');
    INSERT INTO profile_download (candidate_profile_id, downloader_user_id, organisation_id, wallet_ledger_entry_id)
    VALUES (p_candidate_profile_id, current_app_user_id(), p_organisation_id, v_entry)
    RETURNING id INTO v_download;
    PERFORM write_audit('profile.download', 'candidate_profile', p_candidate_profile_id,
                        jsonb_build_object('profile_download_id', v_download), p_organisation_id);
    RETURN v_download;
END $$;
