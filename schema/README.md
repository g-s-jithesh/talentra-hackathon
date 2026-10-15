# Talentra database schema

PostgreSQL 16+ (built and tested on 18.6). Schema `talentra`.

```
psql -d talentra -f schema/build.sql                # builds everything + reference data
psql -d talentra -f schema/tests/smoke_test.sql     # 38 behaviour checks, stops on first failure
```

## Files and owners

| File | Module | Owner |
|---|---|---|
| `00_foundation.sql` | Domains, helpers, i18n, all 53 lookup tables, master data | Team |
| `01_administration.sql` | Users, credentials, roles, permissions, consent, blocking, audit, errors | Member A |
| `02_organisation.sql` | Organisations, hierarchy, locations, tax ids, recruiter mapping, account admins | Scrum master |
| `03_profile.sql` | Candidate profile, contacts, education, experience, skills, resumes, assessments, views, activity, bookmarks, referrals | Team |
| `04_jobs.sql` | Job requirements, questionnaires, applications (partitioned), pipeline history, interviews, offers, search history | Team |
| `05_gig.sql` | Gig worker profiles, services, availability, requests, applications, assignments, earnings, lists, ratings | Member B |
| `06_licences.sql` | Licences, seats, devices, sessions, login history, `start_session()` | Member A |
| `07_billing.sql` | Plans, entitlements, subscriptions, periods, wallet + ledger, payments, invoices, refunds, downloads | Member B |
| `08_sourcing.sql` | Consultant sourcing requests, shortlists, outreach batches and recipients | Scrum master |
| `09_engagement.sql` | Preferences, job alerts, privacy, notifications + deliveries (partitioned), community, support, FAQs | Member B |
| `10_analytics.sql` | Star schema `an_dim_*`, `an_fact_*`, `an_agg_*` | Scrum master |
| `11_security.sql` | DB roles, grants, row-level security, column classification, `data_dictionary` view, retention rules | Member A |
| `90_reference_data.sql` | System user, languages, every lookup code, roles/permissions, base master data, plans | Team |

## Key design decisions

1. **Gigs are a separate subsystem.** They share identity, organisation, skills, wallet and audit, but not `job_requirement` / `application`. Gigs have time windows, pricing, one-way applications, no hiring pipeline, and fulfilment happens in an external system. Reporting across both is done in the analytics layer. The trade-off is two models to maintain.
2. **`application` is hash-partitioned on `job_requirement_id` (16 partitions).** The hot query is "the pipeline of one job". Partitioning this way also keeps `(job, candidate)` uniqueness enforceable and spreads 100M rows evenly. Child tables carry `job_requirement_id` so their foreign key reaches the partition.
3. **`audit_event` and `notification_delivery` use monthly range partitions.** Retention drops a whole partition instead of running a DELETE.
4. **Privileges are enforced in the database:**
   - Row-level security covers 17 tables.
   - The app connects as `talentra_app` and sets `app.user_id` once per transaction.
   - SECURITY DEFINER functions are the only write path for audit, wallet, downloads and sessions.
5. **Concurrency limits use row locks:**
   - Seats lock the `licence` row.
   - Sessions lock the `licence_seat` row.
   - Wallet entries lock the `wallet` row.
   - `start_session()` returns NULL (rather than raising) when the device limit is hit, so the refused attempt stays in `login_attempt` and `audit_event`.
6. **"No overlap" rules are `EXCLUDE USING gist` constraints:**
   - gig assignments per worker
   - worker availability windows
   - subscription periods per licence
   - recruiter mapping per user
   - SCD2 dimension versions
7. **Every user holds a licence seat.** Candidates get one on the Free-plan licence at sign-up, so the device limit applies to everyone.

## Section 5 rule compliance

| Rule group | Complies | How / deviation with reason |
|---|---|---|
| 1 Naming | Yes | snake_case, singular tables, `id` PK, `<table>_id` FKs, `idx_table_column`, `uq_table_column`. Additional patterns: `ck_` checks, `ex_` exclusions, `fk_` named FKs. |
| 2 Keys and constraints | Yes | Identity `bigint` PK (`smallint` for lookups, `integer` for master data). Natural keys are unique constraints. FKs are `NO ACTION` on update and delete unless `ON DELETE CASCADE` is written (owned child rows). Concurrency and licence limits use row locks and EXCLUDE. |
| 3 Standard domains | Yes | Domains `person_name`, `email_address` (lowercase + unique), `phone_e164` + country, `money_amount` + `currency_id`, `percentage`, `rating_score`, `latitude`/`longitude` + source. Enumerations are lookup tables. Unbounded `text` is used only for descriptions, resumes, posts and stack traces, each marked inline. |
| 4 Audit and lifecycle | Yes | `add_standard_columns()` adds `created_at/by`, `updated_at/by` and `deleted_at`, and declares each table soft, hard or append. Soft tables get a `v_<table>` view that excludes deleted rows. Retention rules are in `data_retention_rule`. Deviation: `an_*` tables carry `loaded_at` only, because they are rebuilt by ETL. |
| 5 Nullability | Yes | Every nullable column has an inline `-- null:` reason. Salary has three states (disclosed / not disclosed / not applicable), enforced by trigger, so a zero salary is never used to mean "unknown". |
| 6 Classification | Yes | Column comments `class=…; protection=…`. The `data_dictionary` view lists every column (unlisted columns = Internal). |
| 7 Multilingual | Yes, with deviation | UTF-8; `ui_label` + `ui_translation` with fallback to the default language (`ui_text()`); user content records its language. Deviation: master-data names (cities, skills, roles) are stored once in canonical form because they are data, not UI strings. |
| 8 Physical objects | Yes | Partitions `<table>_pYYYYMM` / `_pdefault` / `_hNN`; views `v_<table>`; analytics prefixed `an_`. |
| Reserved words | Yes | No PostgreSQL or MySQL reserved identifiers (`user` → `app_user`, `order` → `payment_order`). |
| 9 Licences / devices / sessions | Yes | `max_users` and `max_devices_per_user` are positive-checked columns. The limit is enforced at login under lock; refused attempts are audited. Expired or ended sessions don't count. Revocation is audited. |
| 10 Money / history | Yes | The wallet ledger, payment events, download and view history are append-only (trigger + REVOKE). Corrections are reversing entries. Subscription periods can't overlap (EXCLUDE). |

## Open items

- **KPIs:** the analytics marts follow a provisional KPI set until docket Section 8 arrives.
- **Gig ratings:** only completed gigs should be rated; this is enforced in the app layer for now.
- **Retention:** the anonymise job reads `data_retention_rule`; the job itself is not in the schema.
