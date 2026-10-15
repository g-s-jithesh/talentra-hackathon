# Milestone 2: Entities for Profile and Jobs and Applications

Phase 1 · Owner: whole team · Status: **complete, pending team sign-off**

| ID | Backlog | Deliverable | Section |
|---|---|---|---|
| B4 | Identify entities for Profile | Profile entity list | [1](#b4-profile-entity-list) |
| B5 | Validate the Profile entities | Validated Profile entity list | [2](#b5-profile-validation) |
| B6 | Identify entities for Jobs and Applications | Jobs and Applications entity list | [3](#b6-jobs-and-applications-entity-list) |
| B7 | Validate the Jobs and Applications entities | Validated Jobs and Applications entity list | [4](#b7-jobs-and-applications-validation) |

**Lifecycle legend:**
- **soft**: soft-deleted with `deleted_at`, and the `v_<table>` view hides deleted rows.
- **hard**: rows are physically deleted.
- **append**: insert-only; UPDATE and DELETE are rejected.

The DDL for every entity is in [`schema/03_profile.sql`](../schema/03_profile.sql) and [`schema/04_jobs.sql`](../schema/04_jobs.sql).

---

## B4. Profile entity list

19 entities.

| # | Entity | What one row is | Key relationships | Lifecycle | Tier |
|---|---|---|---|---|---|
| 1 | `candidate_profile` | One candidate's profile, 1:1 with a user | `app_user` (1:1), `city`, `gender`, `salary_disclosure`, `profile_visibility` | soft | 1 |
| 2 | `candidate_contact` | An extra email / phone / WhatsApp contact | `candidate_profile` (1:N), `contact_type` | soft | 1 |
| 3 | `candidate_address` | A postal address | `candidate_profile` (1:N), `city` | soft | 1 |
| 4 | `identity_verification` | One national-ID check result (token only, no raw ID) | `app_user` (1:N), `identity_document_type` | hard | 1 |
| 5 | `candidate_education` | One qualification earned or in progress | `candidate_profile` (1:N), `qualification` | soft | 1 |
| 6 | `candidate_experience` | One job held | `candidate_profile` (1:N), `organisation` (optional), `job_role` | soft | 1 |
| 7 | `candidate_skill` | A skill with proficiency and years | `candidate_profile` × `skill` (M:N, unique pair) | hard | 1 |
| 8 | `candidate_language` | A spoken / written language | `candidate_profile` × `language` (M:N, unique pair) | hard | 1 |
| 9 | `profile_project` | A project with role, duration, outcome | `candidate_profile` **or** `gig_worker_profile` (exactly one) | soft | 1 |
| 10 | `resume_template` | A resume layout the builder offers | `ui_label` | hard | 2 |
| 11 | `resume_version` | One version of a resume (built or uploaded) | `candidate_profile` (1:N), `resume_template` | soft | 2 |
| 12 | `assessment` | A test that can be taken | `skill` (optional) | soft | 2 |
| 13 | `assessment_attempt` | One attempt and its score | `assessment` × `candidate_profile` | hard | 2 |
| 14 | `course` | A course offered | none | soft | 2 |
| 15 | `course_enrolment` | A candidate enrolled in a course | `course` × `candidate_profile` (unique pair) | hard | 2 |
| 16 | `profile_view_event` | Who viewed which profile, when | `candidate_profile`, viewer `app_user`, viewer `organisation` | append | 2 |
| 17 | `candidate_activity_event` | Login, profile update, resume download event | `app_user`, `activity_type` | append | 2 |
| 18 | `candidate_bookmark` | Employer / recruiter shortlist or bookmark entry | owner `app_user`, `organisation`, `candidate_profile`, `job_requirement` (optional) | soft (history kept) | 2 |
| 19 | `referral` | One person referred by a user, optionally for a job | referrer and referred `app_user`, `job_requirement` (optional) | hard | 2 |

**Profile completion scoring** (Tier 2) is a column, `candidate_profile.profile_completion_pct`, not a separate entity. It is recalculated whenever the profile changes. A history of scores was judged unnecessary (YAGNI).

**Entities used by Profile but owned elsewhere:**
- `app_user`, `block_entry`, `consent_record` belong to Administration.
- `organisation` belongs to Organisation and account.
- `gig_worker_profile` belongs to Gig.
- `city`, `skill`, `qualification`, `job_role`, `language` and the lookups belong to Master data.

---

## B5. Profile validation

### Coverage: every docket item maps to an entity

| Docket item (Section 4 / Section 7) | Covered by | ✓ |
|---|---|---|
| Personal details | `candidate_profile` (name, date of birth, gender, city, salary expectation) | ✓ |
| Contact details | `app_user.email/phone` + `candidate_contact` + `candidate_address` | ✓ |
| Education | `candidate_education` → `qualification` → `education_level` | ✓ |
| Work experience | `candidate_experience` | ✓ |
| Skills | `candidate_skill` → `skill` | ✓ |
| Languages | `candidate_language` → `language` | ✓ |
| Profile projects: candidate **and** gig projects, with role, duration and outcome | `profile_project` (one-owner check) | ✓ |
| Resume versions and templates | `resume_version`, `resume_template` | ✓ |
| Assessments and scores | `assessment`, `assessment_attempt` | ✓ |
| Course enrolments | `course`, `course_enrolment` | ✓ |
| Profile completion scoring | `candidate_profile.profile_completion_pct` | ✓ |
| Profile view history | `profile_view_event` (append-only) | ✓ |
| Candidate activity log (login, profile update, resume download) | `candidate_activity_event` + `activity_type` codes | ✓ |
| Shortlist and bookmark history for employers and recruiters | `candidate_bookmark` (soft delete keeps history) | ✓ |
| Referral tracking | `referral` + `referral_status` | ✓ |
| National identity check (Section 6 boundary) | `identity_verification`: outcome + token, no raw number | ✓ |

**Result: 16 of 16 items covered, with no orphan entities.**

### Rule checks

These were run on the built database with catalog queries, not checked by eye.

| Check | Result |
|---|---|
| Every entity has a surrogate primary key | ✓ 19 / 19 |
| Every unique constraint is named `uq_…`; every index `idx_…` / `uq_…` | ✓ |
| Every entity declares a lifecycle (soft / hard / append) | ✓ (soft 10, hard 7, append 2) |
| Recruiters cannot register candidates | ✓ `ck_candidate_profile_self_registered` (`created_by = user_id`), tested |
| "Salary not disclosed" is stored differently from "not applicable" and from a zero salary | ✓ `salary_disclosure` lookup + trigger, tested |
| A blocked party cannot see the candidate | ✓ RLS on `candidate_profile` and 9 child tables, tested |
| Every FK to a large parent table has a supporting index | **✗ → fixed** (see below) |

### Issues found and fixed

1. **13 foreign keys in Profile had no supporting index.** Examples are `candidate_address.candidate_profile_id`, `profile_view_event.viewer_organisation_id` and `referral.referred_user_id`. At 10M profiles, "who viewed my profile", company-side view history and cascades from `candidate_profile` would each scan the whole table. Indexes were added at the end of `03_profile.sql`; partial indexes are used where the FK is optional.
2. **FKs to lookup and master-data tables are left unindexed on purpose.** These include `gender_id`, `currency_id` and `city_id`. Lookup rows are deactivated (`is_active = false`), never deleted, so the FK check never scans the child table. This is recorded as a deliberate decision, not a gap.

### Open questions for team review

- **`date_of_birth` and `gender_id`:** keep them optional (current), or remove them? Indian portals collect them, but they raise PII and bias risk.
- **`profile_completion_pct`:** compute it in the app (current), or with a database trigger?

---

## B6. Jobs and Applications entity list

12 entities.

| # | Entity | What one row is | Key relationships | Lifecycle | Notes |
|---|---|---|---|---|---|
| 1 | `job_requirement` | One job posting / requirement | `organisation` (employer), poster `app_user`, `job_category`, `job_role`, `job_status`, `publish_state` | soft | Positions, salary (3-state), experience range, `is_open_to_consultants` |
| 2 | `job_requirement_location` | A city the job is in, with positions per city | `job_requirement` × `city` | hard | |
| 3 | `job_requirement_skill` | A required or preferred skill | `job_requirement` × `skill` | hard | |
| 4 | `questionnaire` | A reusable set of screening questions | `organisation` (1:N) | soft | |
| 5 | `questionnaire_question` | One question | `questionnaire`, `question_type` | hard | |
| 6 | `question_option` | One choice for a choice question | `questionnaire_question` | hard | |
| 7 | `application` | One candidate applying to one job | `job_requirement` × `candidate_profile` (unique), `application_stage`, `application_source`, `sourcing_request`, `resume_version` | hard | **Hash-partitioned ×16 on `job_requirement_id`** |
| 8 | `application_answer` | An answer to one screening question | `application`, `questionnaire_question`, `question_option` | hard | |
| 9 | `application_stage_history` | One pipeline move (applied → shortlisted → …) | `application`, from / to `application_stage` | append | Partitioned like `application` |
| 10 | `interview` | One interview round | `application`, interviewer `app_user`, mode, outcome | soft | |
| 11 | `offer` | An offer, its salary and joining | `application`, `offer_status` | soft | Joins are recorded as `joined_at` |
| 12 | `candidate_search_event` | One job search a candidate ran | `app_user` | append | Tier 2 search history |

**The pipeline is not stored as separate entities.** Applied, shortlisted, interviewed, offered, joined and rejected are `application_stage` codes. `move_application_stage()` changes the stage and writes the history row in one transaction, so the two can never drift. "Rejected" carries its reason in the history row.

---

## B7. Jobs and Applications validation

### Coverage

| Docket item | Covered by | ✓ |
|---|---|---|
| Job requirement posting | `job_requirement` | ✓ |
| Status | `job_status` (draft, open, on hold, closed, filled, cancelled) | ✓ |
| Positions | `positions_total` / `positions_filled` (check: filled ≤ total) + per-city `positions` | ✓ |
| Requirements | experience range, `job_requirement_skill`, `job_role`, salary | ✓ |
| Publish state | `publish_state` + `published_at` / `expires_at` (check: expiry after publish) | ✓ |
| Consultant openness | `is_open_to_consultants`, enforced by the sourcing trigger (tested) | ✓ |
| Questionnaires attached to job requirements | `questionnaire` → `questionnaire_question` → `question_option`; `application_answer` | ✓ |
| Applications | `application` (one per candidate per job) | ✓ |
| Status pipeline: applied, shortlisted, interviewed, offered, joined, rejected | `application_stage` + `application_stage_history` | ✓ |
| Interviews | `interview` (one row per round) | ✓ |
| Offers | `offer` (3-state salary, like jobs) | ✓ |
| Joins | `offer.joined_at` + stage `joined` | ✓ |
| Rejections | stage `rejected` + `reason` in history | ✓ |
| Candidate job search history | `candidate_search_event` | ✓ |
| Candidate application history | `application` by candidate (`idx_application_candidate_profile_id`) + stage history | ✓ |
| Job categories (8 in Section 2) | `job_category` lookup, all 8 codes seeded | ✓ |

**Result: 16 of 16 items covered.**

### Rule checks

| Check | Result |
|---|---|
| Surrogate PK on every entity | ✓ 12 / 12 (partitioned tables: `(id, job_requirement_id)`) |
| Uniqueness still enforced on partitioned `application` | ✓ `uq_application_job_requirement_id_candidate_profile_id` includes the partition key |
| A recruiter sees and changes only their own company's jobs | ✓ RLS, tested |
| Pipeline history cannot be edited | ✓ append-only trigger + REVOKE (same mechanism the tests prove on audit and ledger) |
| Every FK to a large parent table has a supporting index | **✗ → fixed** (see below) |

### Issues found and fixed

1. **8 foreign keys had no supporting index:**
   - `job_requirement.posted_by_user_id`
   - `job_requirement.questionnaire_id`
   - `questionnaire.organisation_id`
   - `questionnaire_question.questionnaire_id`
   - `question_option.questionnaire_question_id`
   - `application_answer.questionnaire_question_id`
   - `interview.interviewer_user_id`
   - `application.sourcing_request_id`

   All were added at the end of `04_jobs.sql`.
2. **Left unindexed on purpose, with reasons:**
   - `application.resume_version_id` is an extra index on a 100M-row table, while resume versions are only soft-deleted, so the FK check never fires.
   - `application_answer.question_option_id`: options are not deleted once answers exist.
   - `candidate_bookmark.job_requirement_id` is covered by `(organisation_id, job_requirement_id)`.

### Open questions for team review

- **Hash partitioning of `application`:** 16 partitions suits a laptop. At full scale (100M rows), 32–64 may be better, and B74's extrapolation should decide.
- **Status vs publish state:** keep `job_status` and `publish_state` separate (current), or merge them? They are separate because a job can be *open* internally but *unpublished*, for example a confidential hire.

---

### Evidence

- Build: `psql -f schema/build.sql` completes with no errors after the index fixes.
- Tests: `schema/tests/smoke_test.sql` passes 38 of 38 after the fixes.

### Sign-off (B5 / B7 peer validation)

| Member | Profile (B5) | Jobs and Applications (B7) | Date |
|---|---|---|---|
| Member A | ☐ | ☐ | |
| Member B | ☐ | ☐ | |
| Scrum master | ☐ | ☐ | |
