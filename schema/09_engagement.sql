-- =============================================================================
-- Talentra schema - 09 Notifications, preferences and community (Member B)
-- Preferences (notification, job alert, privacy; language is on app_user),
-- notifications and their delivery log, community posts, support, FAQs.
-- notification_delivery is the high-volume write path: monthly range partitions,
-- append-only status events, no message bodies stored.
-- =============================================================================
SET search_path = talentra, public;

CREATE TABLE notification_preference (
    id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id                  bigint NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    notification_category_id smallint NOT NULL REFERENCES notification_category (id),
    channel_id               smallint NOT NULL REFERENCES channel (id),
    is_enabled               boolean NOT NULL DEFAULT true,
    CONSTRAINT uq_notification_preference_user_category_channel UNIQUE (user_id, notification_category_id, channel_id)
);
CALL add_standard_columns('notification_preference', 'hard');

CREATE TABLE job_alert (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id            bigint NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    name               varchar(100) NOT NULL,
    keywords           varchar(200),                       -- null: filter-only alert
    city_id            integer REFERENCES city (id),       -- null: any city
    job_role_id        integer REFERENCES job_role (id),   -- null: any role
    job_category_id    smallint REFERENCES job_category (id),  -- null: any category
    min_salary         money_amount,                       -- null: no salary filter
    currency_id        smallint REFERENCES currency (id),
    alert_frequency_id smallint NOT NULL REFERENCES alert_frequency (id),
    is_active          boolean NOT NULL DEFAULT true,
    last_sent_at       timestamptz,                        -- null: never sent
    CONSTRAINT ck_job_alert_salary CHECK ((min_salary IS NULL) = (currency_id IS NULL))
);
CALL add_standard_columns('job_alert', 'soft');
CREATE INDEX idx_job_alert_due ON job_alert (alert_frequency_id, last_sent_at) WHERE is_active AND deleted_at IS NULL;

CREATE TABLE privacy_setting (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id                bigint NOT NULL CONSTRAINT uq_privacy_setting_user_id UNIQUE REFERENCES app_user (id) ON DELETE CASCADE,
    show_contact_details   boolean NOT NULL DEFAULT false,   -- contacts visible only after an application / download
    allow_recruiter_search boolean NOT NULL DEFAULT true,
    allow_data_for_analytics boolean NOT NULL DEFAULT true
);
CALL add_standard_columns('privacy_setting', 'hard');

CREATE TABLE notification (
    id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id                  bigint NOT NULL REFERENCES app_user (id),
    notification_category_id smallint NOT NULL REFERENCES notification_category (id),
    template_key             varchar(100) NOT NULL,
    payload                  jsonb NOT NULL DEFAULT '{}',   -- template variables (ids, names), not rendered text
    read_at                  timestamptz                    -- null: unread (in-app)
);
CALL add_standard_columns('notification', 'hard');
CREATE INDEX idx_notification_user_id_unread ON notification (user_id, created_at DESC) WHERE read_at IS NULL;

CREATE TABLE notification_delivery (
    id                  bigint GENERATED ALWAYS AS IDENTITY,
    created_at          timestamptz NOT NULL DEFAULT now(),
    notification_id     bigint NOT NULL REFERENCES notification (id),
    channel_id          smallint NOT NULL REFERENCES channel (id),
    provider_name       varchar(40) NOT NULL,
    provider_message_id varchar(100),                 -- null: provider never accepted the message
    delivery_status_id  smallint NOT NULL REFERENCES delivery_status (id),
    attempt_number      smallint NOT NULL DEFAULT 1 CHECK (attempt_number > 0),
    error_code          varchar(40),                  -- null: no error
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
CALL create_monthly_partitions('notification_delivery', DATE '2026-10-01', 6);
CALL make_append_only('notification_delivery');      -- each status change is a new row
CREATE INDEX idx_notification_delivery_notification_id ON notification_delivery (notification_id, created_at DESC);
-- A unique index on a partitioned table must include created_at, which would not
-- stop a redelivered callback; duplicates are filtered with this lookup instead.
CREATE INDEX idx_notification_delivery_provider_message_id
    ON notification_delivery (provider_name, provider_message_id) WHERE provider_message_id IS NOT NULL;

CREATE TABLE community_post (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    author_user_id bigint NOT NULL REFERENCES app_user (id),
    parent_post_id bigint REFERENCES community_post (id),   -- null: top-level post; set: reply
    title          varchar(200),                            -- null for replies
    body           text NOT NULL,                           -- unbounded: user post
    language_id    smallint REFERENCES language (id),       -- null: not detected
    CONSTRAINT ck_community_post_title CHECK ((parent_post_id IS NULL) = (title IS NOT NULL))
);
CALL add_standard_columns('community_post', 'soft');
CREATE INDEX idx_community_post_parent_post_id ON community_post (parent_post_id, created_at);

CREATE TABLE post_reaction (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    community_post_id bigint NOT NULL REFERENCES community_post (id) ON DELETE CASCADE,
    user_id           bigint NOT NULL REFERENCES app_user (id),
    reaction_type_id  smallint NOT NULL REFERENCES reaction_type (id),
    CONSTRAINT uq_post_reaction_post_user UNIQUE (community_post_id, user_id)
);
CALL add_standard_columns('post_reaction', 'hard');

CREATE TABLE support_ticket (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raised_by_user_id   bigint NOT NULL REFERENCES app_user (id),
    assigned_to_user_id bigint REFERENCES app_user (id),      -- null: not triaged yet
    subject             varchar(200) NOT NULL,
    description         varchar(4000) NOT NULL,
    language_id         smallint REFERENCES language (id),    -- null: not detected
    ticket_status_id    smallint NOT NULL REFERENCES ticket_status (id),
    ticket_priority_id  smallint NOT NULL REFERENCES ticket_priority (id),
    resolved_at         timestamptz                           -- null: open
);
CALL add_standard_columns('support_ticket', 'hard');
CREATE INDEX idx_support_ticket_status ON support_ticket (ticket_status_id, ticket_priority_id);

CREATE TABLE support_ticket_message (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    support_ticket_id bigint NOT NULL REFERENCES support_ticket (id),
    author_user_id    bigint NOT NULL REFERENCES app_user (id),
    body              varchar(4000) NOT NULL,
    is_internal_note  boolean NOT NULL DEFAULT false
);
CALL add_standard_columns('support_ticket_message', 'append');
CREATE INDEX idx_support_ticket_message_ticket_id ON support_ticket_message (support_ticket_id, created_at);

CREATE TABLE faq (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    faq_category_id smallint NOT NULL REFERENCES faq_category (id),
    sort_order      smallint NOT NULL DEFAULT 0,
    is_published    boolean NOT NULL DEFAULT false
);
CALL add_standard_columns('faq', 'soft');

CREATE TABLE faq_translation (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    faq_id      integer NOT NULL REFERENCES faq (id) ON DELETE CASCADE,
    language_id smallint NOT NULL REFERENCES language (id),
    question    varchar(500) NOT NULL,
    answer      text NOT NULL,                          -- unbounded: help article body
    CONSTRAINT uq_faq_translation_faq_id_language_id UNIQUE (faq_id, language_id)
);
CALL add_standard_columns('faq_translation', 'hard');
