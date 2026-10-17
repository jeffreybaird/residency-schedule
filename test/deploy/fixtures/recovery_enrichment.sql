-- Synthetic records only. Run against a disposable copy of persistent staging.
-- This does not touch the original staging database or any production database.
\set ON_ERROR_STOP on
BEGIN;
DO $fixture$
DECLARE
  actor bigint;
  override_row shift_overrides%ROWTYPE;
  client bigint;
BEGIN
  IF current_database() !~ '^residency_schedule_recovery_source_[a-z0-9_]+$' THEN
    RAISE EXCEPTION 'disposable recovery source required';
  END IF;
  SELECT id INTO STRICT actor FROM users WHERE email = 'staging-admin@example.test';
  SELECT * INTO STRICT override_row FROM shift_overrides
    WHERE override_start_date = DATE '2025-07-03'
      AND override_end_date = DATE '2025-07-04';
  INSERT INTO schedule_change_requests
    (rotation_id, covering_schedule_resident_id, start_date, end_date, status,
     note, requested_by_user_id, reviewed_by_user_id, reviewed_at, review_note,
     shift_override_id, inserted_at, updated_at)
  VALUES
    (override_row.rotation_id, override_row.covering_schedule_resident_id,
     override_row.override_start_date, override_row.override_end_date, 'approved',
     'Synthetic recovery coverage request note', actor, actor,
     TIMESTAMP '2026-10-17 00:00:00', 'Synthetic recovery approval note',
     override_row.id, TIMESTAMP '2026-10-17 00:00:00', TIMESTAMP '2026-10-17 00:00:00');
  INSERT INTO oauth_clients
    (client_id, client_name, redirect_uris, token_endpoint_auth_method, inserted_at, updated_at)
  VALUES
    ('synthetic-recovery-client', 'Synthetic recovery client',
     ARRAY['https://recovery.example.test/callback'], 'none',
     TIMESTAMP '2026-10-17 00:00:00', TIMESTAMP '2026-10-17 00:00:00')
  RETURNING id INTO client;
  INSERT INTO oauth_authorization_codes
    (code_hash, client_id, user_id, redirect_uri, code_challenge,
     code_challenge_method, scope, resource, expires_at, inserted_at, updated_at)
  VALUES
    ('synthetic-recovery-code-hash', client, actor,
     'https://recovery.example.test/callback', 'synthetic-recovery-code-challenge',
     'S256', 'read', 'https://recovery.example.test/mcp', TIMESTAMP '2030-01-01',
     TIMESTAMP '2026-10-17 00:00:00', TIMESTAMP '2026-10-17 00:00:00');
  INSERT INTO oauth_tokens
    (access_token_hash, refresh_token_hash, client_id, user_id, scope, resource,
     expires_at, inserted_at, updated_at)
  VALUES
    ('synthetic-recovery-access-hash', 'synthetic-recovery-refresh-hash', client, actor,
     'read', 'https://recovery.example.test/mcp', TIMESTAMP '2030-01-01',
     TIMESTAMP '2026-10-17 00:00:00', TIMESTAMP '2026-10-17 00:00:00');
  INSERT INTO magic_link_tokens (token, expires_at, user_id, inserted_at, updated_at)
  VALUES ('synthetic-recovery-magic-link', TIMESTAMP '2030-01-01', actor,
          TIMESTAMP '2026-10-17 00:00:00', TIMESTAMP '2026-10-17 00:00:00');
END;
$fixture$;
COMMIT;
