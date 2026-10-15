-- Build the whole Talentra schema into the current database:
--   psql -d talentra -f schema/build.sql
\set ON_ERROR_STOP on
\ir 00_foundation.sql
\ir 01_administration.sql
\ir 02_organisation.sql
\ir 03_profile.sql
\ir 04_jobs.sql
\ir 05_gig.sql
\ir 06_licences.sql
\ir 07_billing.sql
\ir 08_sourcing.sql
\ir 09_engagement.sql
\ir 10_analytics.sql
\ir 11_security.sql
\ir 90_reference_data.sql
