-- Read-only representative semantic assertions; no row values or tokens output.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $checks$
DECLARE
  vacation_days bigint;
BEGIN
  IF current_database() !~ '^residency_schedule_recovery_[a-z0-9_]+$' THEN
    RAISE EXCEPTION 'disposable recovery database required';
  END IF;
  WITH subject AS (
    SELECT sr.id FROM schedule_residents sr
      JOIN residents r ON r.id = sr.resident_id
      JOIN schedules s ON s.id = sr.schedule_id
      WHERE r.name = 'Stage Briar' AND s.academic_year = 2026
  ), days AS (
    SELECT day::date FROM rotations r JOIN subject s ON s.id = r.schedule_resident_id
      CROSS JOIN LATERAL generate_series(r.start_date::timestamp,
        r.end_date::timestamp, INTERVAL '1 day') day
      WHERE r.rotation_type = 'vacation'
    UNION
    SELECT a.date FROM detailed_activities a JOIN subject s ON s.id = a.schedule_resident_id
      WHERE lower(a.raw_task) = 'vacation'
  )
  SELECT count(*) INTO vacation_days FROM days
    WHERE day BETWEEN DATE '2027-04-05' AND DATE '2027-04-18';
  IF vacation_days <> 14 THEN
    RAISE EXCEPTION 'vacation chain semantic check failed';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM schedule_change_requests c
      JOIN shift_overrides o ON o.id = c.shift_override_id
      JOIN users u ON u.id = c.requested_by_user_id
      JOIN users reviewer ON reviewer.id = c.reviewed_by_user_id
      WHERE c.status = 'approved' AND c.rotation_id = o.rotation_id
        AND c.covering_schedule_resident_id = o.covering_schedule_resident_id
        AND c.start_date = o.override_start_date AND c.end_date = o.override_end_date
        AND c.note = 'Synthetic recovery coverage request note'
        AND c.review_note = 'Synthetic recovery approval note'
        AND c.reviewed_at IS NOT NULL AND u.approved AND reviewer.role = 'admin'
  ) THEN
    RAISE EXCEPTION 'coverage and notes semantic check failed';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM detailed_activity_sources p JOIN detailed_activities a ON a.id = p.activity_id
      JOIN detailed_import_batches b ON b.id = p.batch_id
      WHERE cardinality(p.notes) > 0 AND b.fingerprint = 'synthetic-staging-vacation-v1'
  ) THEN
    RAISE EXCEPTION 'activity provenance semantic check failed';
  END IF;
  IF (SELECT count(*) FROM residents WHERE calendar_token IS NOT NULL AND calendar_token <> '') <> 2
    OR NOT EXISTS (SELECT 1 FROM users WHERE email = 'staging-admin@example.test' AND password_hash IS NOT NULL)
    OR NOT EXISTS (SELECT 1 FROM oauth_tokens t JOIN oauth_clients c ON c.id = t.client_id
      JOIN users u ON u.id = t.user_id WHERE c.client_id = 'synthetic-recovery-client'
        AND t.access_token_hash = 'synthetic-recovery-access-hash'
        AND t.refresh_token_hash = 'synthetic-recovery-refresh-hash')
    OR NOT EXISTS (SELECT 1 FROM oauth_authorization_codes WHERE code_hash = 'synthetic-recovery-code-hash')
    OR NOT EXISTS (SELECT 1 FROM magic_link_tokens WHERE token = 'synthetic-recovery-magic-link')
  THEN
    RAISE EXCEPTION 'authentication and feed preservation check failed';
  END IF;
END;
$checks$;
SELECT json_build_object('vacation_chain_14_days', true, 'approved_coverage_and_notes', true,
  'activity_provenance', true, 'authentication_and_feed_records', true);
COMMIT;
