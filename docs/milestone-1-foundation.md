# Milestone 1: Identify and fix the DB provider

Phase 1 · Owner: whole team · Status: **complete, pending team sign-off**

| ID | Backlog | Deliverable | Section |
|---|---|---|---|
| B1 | Identify and fix the DB provider with a reason | DB provider decision | [1](#b1-db-provider-decision) |
| B2 | Read the requirement document and agree the module list | Agreed module list | [2](#b2-agreed-module-list) |
| B3 | Assign the common modules | Common module assignment | [3](#b3-common-module-assignment) |

---

## B1. DB provider decision

**Decision: PostgreSQL 16 or later. The build is verified on PostgreSQL 18.6.**

### Why PostgreSQL

The docket requires several rules to be enforced *by the database*, not the application. The table shows which of them PostgreSQL can enforce declaratively and what MySQL 8 would need instead.

| Docket requirement | PostgreSQL feature used | MySQL 8 equivalent |
|---|---|---|
| Gig windows cannot overlap per worker (B35); subscription periods cannot overlap (rule 10, B47) | `EXCLUDE USING gist (worker WITH =, tstzrange(...) WITH &&)` | No exclusion constraints. Needs triggers that lock and re-check, which is race-prone. |
| Recruiter sees only their own company's jobs; a blocked party cannot see the candidate (Section 3) | Row-level security policies | No RLS. Needs a view per role plus application filtering. |
| Device limit under concurrent logins (rule 9, B45) | `SELECT … FOR UPDATE` on the seat row inside a function | Possible |
| 100M applications; retention by dropping partitions | Declarative hash and range partitioning, with FKs to and from partitioned tables | Partitioned tables cannot have foreign keys |
| Soft-delete-aware uniqueness ("one live email", "one primary resume") | Partial unique indexes (`WHERE deleted_at IS NULL`) | Not supported (needs generated-column workarounds) |
| Standard domains (rule 3) | `CREATE DOMAIN email_address … CHECK (lower)` | No domains; the check is repeated on every column |
| Append-only ledgers and audit (rules 4 and 10) | Triggers that reject UPDATE, DELETE and TRUNCATE, plus `REVOKE` | Triggers exist; TRUNCATE cannot be trapped |
| Seeding 1M profiles and 5M applications on a laptop | `COPY`, `generate_series` | `LOAD DATA INFILE` (comparable) |
| Job search | GIN + `tsvector`, `pg_trgm` | FULLTEXT (comparable) |

### Trade-offs we accept

- **Write amplification:** MVCC on the application pipeline. Mitigated by hash partitioning and a narrow `application` row.
- **Maintenance:** VACUUM on the high-churn tables (`user_session`, `application`). Autovacuum is tuned per partition.
- **Learning curve:** RLS and exclusion constraints are new to some of the team. Mitigated by keeping every policy in one file (`11_security.sql`) with tests.

### Portability

Identifiers avoid both PostgreSQL and MySQL reserved words, which was checked against both keyword lists. A MySQL port would therefore change features, not names.

---

## B2. Agreed module list

There are eleven modules from docket Section 7, plus one stretch module. Every Section 4 item has exactly one owning module; the full coverage check is in Milestone 2.

| # | Module | Type | Scope | Schema file |
|---|---|---|---|---|
| 1 | Master data | Common (P1) | Countries, states, cities, currencies, skills, qualifications, industries, job roles, every enumeration (53 lookups), UI translation keys | `00_foundation.sql` |
| 2 | Profile | Common (P1) | Candidate identity and contact, education, experience, skills, languages, resumes and templates, projects, assessments, courses, completion score, profile views, activity log, bookmarks, referrals | `03_profile.sql` |
| 3 | Jobs and Applications | Common (P1) | Job requirements, positions, questionnaires, publish state, applications, status pipeline, interviews, offers, joins, rejections, search history | `04_jobs.sql` |
| 4 | Administration | Individual (P2) | Users, credentials, roles, permissions, consent, blocking lists, audit trail, system errors | `01_administration.sql` |
| 5 | Organisation and account | Individual (P2) | Organisations, hierarchy, locations, tax identifiers, verification, recruiter mapping, account administrators | `02_organisation.sql` |
| 6 | Gig marketplace | Individual (P2) | Gig requests, worker profiles, services, availability, applications, assignments, handoff references, earnings, lists, ratings | `05_gig.sql` |
| 7 | Licences, seats, devices and sessions | Individual (P3) | Licences, seats, devices, sessions, login history, limits, revocation | `06_licences.sql` |
| 8 | Sourcing and consultant requests | Individual (P3) | Sourcing requests, consultant openness, accept or decline, outreach batches and recipients, sourcing shortlists | `08_sourcing.sql` |
| 9 | Subscriptions, wallet, payments, downloads | Individual (P3) | Plans, periods, renewals, entitlements, payment orders, invoices, refunds, wallet ledger, credit consumption, download history | `07_billing.sql` |
| 10 | Notifications, preferences, community | Individual (P4) | Notification, alert, language and privacy preferences, delivery status, posts, reactions, tickets, FAQs | `09_engagement.sql` |
| 11 | Analytics and reporting marts | Individual (P4) | Star schema, dimensions, facts, aggregates | `10_analytics.sql` |
| S | Tier 3 stretch | Optional | Salary benchmarks, company ratings, trending jobs, dashboard aggregates, feature flags | Not started (decision deferred to Day 2) |

Security (grants, RLS, classification, retention) is cross-cutting and lives in `11_security.sql`, owned by Member A.

### Central vs secondary workflows

Docket Section 2 asks us to decide which workflows are central and to justify it.

| Workflow | Classification | Reason |
|---|---|---|
| Candidate registration, profile building, resume | **Central** | Retention problem in the docket; 10M-profile scale target |
| Job search, application, status tracking | **Central** | The hiring pipeline is the "single view" the docket says is missing |
| Employer registration, verification, job posting | **Central** | Supplies every job; tenant boundary for RLS |
| Gig requests and applications | **Central** | Named as the primary revenue category |
| Wallet recharge and credit consumption | **Central** | Monetises downloads, outreach and postings |
| Candidate sourcing and bulk outreach | Secondary | Depends on Profile and Wallet; no new core entity |
| Consultant requests | Secondary | A permission layer over existing jobs |
| Questionnaires | Secondary | Optional per job |
| Blocking users and companies | Secondary as a workflow, central as a **rule** | Few writes, but enforced on every read (RLS) |
| Notifications and job alerts | Secondary | Derived from other events |
| Support tickets and FAQs | Secondary | Isolated; no other module depends on them |

Central workflows get indexes, partitioning and performance tests (Milestone 21). Secondary ones get correctness only.

---

## B3. Common module assignment

| Module | Owner | Working mode |
|---|---|---|
| Master data | Whole team | Designed first (everything references it); the scrum master drives |
| Profile | Whole team | Mob session, one driver, others review live |
| Jobs and Applications | Whole team | Mob session; the core tables are frozen afterwards |

**Frozen core tables after Phase 1:** `app_user`, `organisation`, `candidate_profile`, `job_requirement`, `application`. Any change to them goes through the scrum master, because every individual module references them.

**Individual module owners (fixed for all later phases):**

| Owner | Modules | Cross-cutting |
|---|---|---|
| Member A: Vennela Reddy Vootkur | Administration, Licences / devices / sessions, Security | RLS, access tests, threat model |
| Member B: Venkata Sai Vardhan Sangam | Gig marketplace, Subscriptions / wallet / payments, Notifications | Seed generator lead |
| Scrum master: Jithesh Gopalan Srinivasan | Organisation and account, Sourcing, Analytics | Docs, compliance table, boundary table, competitor matrix |

**Review rotation for every "validate" backlog item:** A reviews B, B reviews the scrum master, and the scrum master reviews A.

---

### Sign-off

| Member | Reviewed | Date |
|---|---|---|
| Member A | ☐ | |
| Member B | ☐ | |
| Scrum master | ☐ | |
