-- Run as the database administrator, connected to residency_schedule_prod, with
-- psql -X -v ON_ERROR_STOP=1 -v expected_cluster_identifier=<verified identifier>.
-- This is an explicit provisioning operation, never run by the backup service.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path TO pg_catalog;
SELECT set_config('phase0.expected_cluster_identifier', :'expected_cluster_identifier', true);

DO $bootstrap$
DECLARE
  schema_name text;
BEGIN
  IF current_database() <> 'residency_schedule_prod' OR pg_is_in_recovery() THEN
    RAISE EXCEPTION 'backup bootstrap requires the designated primary database';
  END IF;
  IF (SELECT system_identifier::text FROM pg_control_system()) <>
       current_setting('phase0.expected_cluster_identifier') THEN
    RAISE EXCEPTION 'backup bootstrap cluster identity mismatch';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rs_backup') THEN
    RAISE EXCEPTION 'backup role already exists; inspect it without modifying it';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_roles r ON r.oid = c.relowner
    WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
      AND c.relkind IN ('r', 'S', 'p', 'm', 'f') AND r.rolname <> 'postgres'
  ) THEN
    RAISE EXCEPTION 'unexpected application object owner; review backup grants';
  END IF;

  CREATE ROLE rs_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOINHERIT NOBYPASSRLS;
  ALTER ROLE rs_backup SET default_transaction_read_only = on;
  GRANT CONNECT ON DATABASE residency_schedule_prod TO rs_backup;
  GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO rs_backup;
  -- Only these nonsensitive columns are needed to reject subscriptions in the
  -- selected database. In particular, never grant access to subconninfo.
  GRANT SELECT (oid, subdbid) ON pg_catalog.pg_subscription TO rs_backup;

  FOR schema_name IN
    SELECT nspname FROM pg_namespace
    WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO rs_backup', schema_name);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO rs_backup', schema_name);
    EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO rs_backup', schema_name);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT ON TABLES TO rs_backup', schema_name);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT ON SEQUENCES TO rs_backup', schema_name);
  END LOOP;
END
$bootstrap$;
COMMIT;
