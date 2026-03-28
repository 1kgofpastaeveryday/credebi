-- ============================================================
-- pg_cron job definitions
-- Requires: pg_cron, pg_net extensions
-- Requires: app.supabase_url and app.internal_sync_secret DB parameters
-- ============================================================

-- Seed heartbeat expectations. Edge Functions must update last_success_at by calling
-- record_system_heartbeat(...) only after a successful run.
INSERT INTO system_heartbeats (job_name, expected_interval, details)
VALUES
  ('detect-broken-connections', INTERVAL '12 hours', '{"owner":"pg_cron","kind":"dead_mans_switch"}'::jsonb),
  ('renew-gmail-watches', INTERVAL '24 hours', '{"owner":"edge_function","kind":"heartbeat_required"}'::jsonb),
  ('update-projection', INTERVAL '24 hours', '{"owner":"edge_function","kind":"heartbeat_required"}'::jsonb),
  ('nudge-balance-update', INTERVAL '24 hours', '{"owner":"edge_function","kind":"heartbeat_required"}'::jsonb)
ON CONFLICT (job_name) DO NOTHING;

-- TTL cleanup: processed_webhook_messages (7日超)
SELECT cron.schedule(
  'cleanup-processed-webhook-messages',
  '0 3 * * *',
  $$DELETE FROM processed_webhook_messages
    WHERE status = 'done' AND processed_at < now() - INTERVAL '7 days'$$
);

-- TTL cleanup: pending_ec_correlations (30日超)
SELECT cron.schedule(
  'cleanup-pending-ec-correlations',
  '0 3 * * *',
  $$DELETE FROM pending_ec_correlations
    WHERE created_at < now() - INTERVAL '30 days'$$
);

-- Stale pending webhook alert (24h+ pending → system_alert)
SELECT cron.schedule(
  'alert-stale-pending-messages',
  '0 */6 * * *',
  $$INSERT INTO system_alerts (alert_type, message, created_at)
    SELECT 'stale_pending_webhook',
           format('message_id=%s pending since %s', message_id, processed_at),
           now()
    FROM processed_webhook_messages pwm
    WHERE pwm.status = 'pending'
      AND pwm.processed_at < now() - INTERVAL '24 hours'
      AND NOT EXISTS (
        SELECT 1 FROM system_alerts sa
        WHERE sa.alert_type = 'stale_pending_webhook'
          AND sa.resolved_at IS NULL
          AND sa.message LIKE format('message_id=%s%%', pwm.message_id)
      )$$
);

-- Gmail watch renewal (daily)
-- Heartbeat contract: renew-gmail-watch Edge Function must call
--   SELECT record_system_heartbeat('renew-gmail-watches', INTERVAL '24 hours');
-- after a successful end-to-end run. pg_net dispatch alone is not success.
SELECT cron.schedule(
  'renew-gmail-watches',
  '0 2 * * *',
  $$SELECT net.http_post(
    url := current_setting('app.supabase_url') || '/functions/v1/renew-gmail-watch',
    headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.internal_sync_secret')),
    body := '{}'::jsonb
  )$$
);

-- Monthly summaries update (daily)
-- Heartbeat contract: update-projection Edge Function must call
--   SELECT record_system_heartbeat('update-projection', INTERVAL '24 hours');
-- after a successful fan-out / completion pass.
SELECT cron.schedule(
  'update-monthly-summaries',
  '30 3 * * *',
  $$SELECT net.http_post(
    url := current_setting('app.supabase_url') || '/functions/v1/update-projection',
    headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.internal_sync_secret')),
    body := '{}'::jsonb
  )$$
);

-- Advance projected_incomes.next_occurs_at (calendar-safe)
SELECT cron.schedule(
  'advance-projected-income-dates',
  '0 4 * * *',
  $$
  -- Monthly: calendar-month arithmetic (no 30-day drift)
  UPDATE projected_incomes pi
  SET next_occurs_at = adv.new_date,
      updated_at = now()
  FROM (
    SELECT pi2.id, (
      SELECT d::date FROM generate_series(
        pi2.next_occurs_at, (NOW() AT TIME ZONE 'Asia/Tokyo')::date + INTERVAL '2 months', INTERVAL '1 month'
      ) AS d
      WHERE d::date >= (NOW() AT TIME ZONE 'Asia/Tokyo')::date
      ORDER BY d LIMIT 1
    ) AS new_date
    FROM projected_incomes pi2
    WHERE pi2.is_active = true
      AND pi2.recurrence = 'monthly'
      AND pi2.next_occurs_at < (NOW() AT TIME ZONE 'Asia/Tokyo')::date
  ) adv
  WHERE pi.id = adv.id AND adv.new_date IS NOT NULL;

  -- Weekly: 7-day arithmetic is exact
  UPDATE projected_incomes
  SET next_occurs_at = next_occurs_at
        + (INTERVAL '7 days' * CEIL(
            ((NOW() AT TIME ZONE 'Asia/Tokyo')::date - next_occurs_at)::numeric / 7
          )),
      updated_at = now()
  WHERE is_active = true
    AND recurrence = 'weekly'
    AND next_occurs_at < (NOW() AT TIME ZONE 'Asia/Tokyo')::date;
  $$
);

-- Advance subscriptions.next_billing_at (calendar-safe + installment termination)
SELECT cron.schedule(
  'advance-subscription-billing-dates',
  '10 4 * * *',
  $$
  -- Monthly subscriptions
  UPDATE subscriptions s
  SET next_billing_at = adv.new_date,
      updated_at = now()
  FROM (
    SELECT s2.id, (
      SELECT d::date FROM generate_series(
        s2.next_billing_at, (NOW() AT TIME ZONE 'Asia/Tokyo')::date + INTERVAL '2 months', INTERVAL '1 month'
      ) AS d
      WHERE d::date >= (NOW() AT TIME ZONE 'Asia/Tokyo')::date
      ORDER BY d LIMIT 1
    ) AS new_date
    FROM subscriptions s2
    WHERE s2.is_active = true
      AND s2.billing_cycle = 'monthly'
      AND s2.next_billing_at IS NOT NULL
      AND s2.next_billing_at < (NOW() AT TIME ZONE 'Asia/Tokyo')::date
  ) adv
  WHERE s.id = adv.id AND adv.new_date IS NOT NULL;

  -- Weekly subscriptions
  UPDATE subscriptions
  SET next_billing_at = next_billing_at
        + (INTERVAL '7 days' * CEIL(
            ((NOW() AT TIME ZONE 'Asia/Tokyo')::date - next_billing_at)::numeric / 7
          )),
      updated_at = now()
  WHERE is_active = true
    AND billing_cycle = 'weekly'
    AND next_billing_at IS NOT NULL
    AND next_billing_at < (NOW() AT TIME ZONE 'Asia/Tokyo')::date;

  -- Yearly subscriptions
  UPDATE subscriptions s
  SET next_billing_at = adv.new_date,
      updated_at = now()
  FROM (
    SELECT s2.id, (
      SELECT d::date FROM generate_series(
        s2.next_billing_at, (NOW() AT TIME ZONE 'Asia/Tokyo')::date + INTERVAL '2 years', INTERVAL '1 year'
      ) AS d
      WHERE d::date >= (NOW() AT TIME ZONE 'Asia/Tokyo')::date
      ORDER BY d LIMIT 1
    ) AS new_date
    FROM subscriptions s2
    WHERE s2.is_active = true
      AND s2.billing_cycle = 'yearly'
      AND s2.next_billing_at IS NOT NULL
      AND s2.next_billing_at < (NOW() AT TIME ZONE 'Asia/Tokyo')::date
  ) adv
  WHERE s.id = adv.id AND adv.new_date IS NOT NULL;

  -- Deactivate completed installments (DT-110)
  UPDATE subscriptions
  SET is_active = false,
      updated_at = now()
  WHERE is_active = true
    AND subscription_type = 'installment'
    AND (
      (remaining_count IS NOT NULL AND remaining_count <= 0)
      OR (expected_end_at IS NOT NULL AND next_billing_at > expected_end_at)
    );
  $$
);

-- Bank balance update nudge (payday翌日にPush)
-- Heartbeat contract: nudge-balance-update Edge Function must call
--   SELECT record_system_heartbeat('nudge-balance-update', INTERVAL '24 hours');
-- on success so pg_net fire-and-forget failures are externally visible.
SELECT cron.schedule(
  'nudge-balance-update',
  '0 0 * * *',
  $$SELECT net.http_post(
    url := current_setting('app.supabase_url') || '/functions/v1/nudge-balance-update',
    headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.internal_sync_secret')),
    body := '{}'::jsonb
  )$$
);

-- Dead Man's Switch: broken connection detection (12h interval)
SELECT cron.schedule(
  'detect-broken-connections',
  '0 */12 * * *',
  $$
  SELECT record_system_heartbeat(
    'detect-broken-connections',
    INTERVAL '12 hours',
    now(),
    'ok',
    jsonb_build_object('source', 'pg_cron')
  );

  -- Part 1: Email connections (stale sync OR expired watch)
  WITH broken_email AS (
    UPDATE email_connections
    SET is_active = false,
        last_error = COALESCE(last_error, 'stale_sync_48h')
    WHERE is_active = true
      AND (
        last_synced_at < now() - INTERVAL '48 hours'
        OR watch_expiry < now()
      )
    RETURNING id, user_id, last_synced_at
  )
  INSERT INTO system_alerts (user_id, alert_type, message, email_connection_id)
  SELECT user_id, 'broken_connection',
         format('email_connection %s inactive: last_synced_at=%s', id, last_synced_at),
         id
  FROM broken_email
  WHERE id NOT IN (
    SELECT email_connection_id FROM system_alerts
    WHERE alert_type = 'broken_connection'
      AND resolved_at IS NULL
      AND email_connection_id IS NOT NULL
  );

  -- Part 2: Income connections (stale sync)
  WITH broken_income AS (
    UPDATE income_connections
    SET is_active = false,
        last_error = COALESCE(last_error, 'stale_sync_48h')
    WHERE is_active = true
      AND last_synced_at < now() - INTERVAL '48 hours'
    RETURNING id, user_id, last_synced_at
  )
  INSERT INTO system_alerts (user_id, alert_type, message, income_connection_id)
  SELECT user_id, 'broken_connection',
         format('income_connection %s inactive: last_synced_at=%s', id, last_synced_at),
         id
  FROM broken_income
  WHERE id NOT IN (
    SELECT income_connection_id FROM system_alerts
    WHERE alert_type = 'broken_connection'
      AND resolved_at IS NULL
      AND income_connection_id IS NOT NULL
  );
  $$
);

-- TTL cleanup: api_idempotency_keys (24h超)
SELECT cron.schedule(
  'cleanup-api-idempotency-keys',
  '0 4 * * *',
  $$DELETE FROM api_idempotency_keys WHERE created_at < now() - INTERVAL '24 hours'$$
);

-- TTL cleanup: rate_limit_counters (10分超)
SELECT cron.schedule(
  'cleanup-rate-limit-counters',
  '*/10 * * * *',
  $$DELETE FROM rate_limit_counters WHERE created_at < now() - INTERVAL '10 minutes'$$
);

-- DT-205/206: Heartbeat freshness monitor (every 30 minutes)
SELECT cron.schedule(
  'check-heartbeat-freshness',
  '*/30 * * * *',
  $$
  INSERT INTO system_alerts (user_id, alert_type, message, created_at)
  SELECT NULL, 'stale_heartbeat',
         'Cron job ' || h.job_name || ' last succeeded at ' || h.last_success_at::text,
         now()
  FROM system_heartbeats h
  WHERE h.last_success_at < now() - h.expected_interval * 2
    AND NOT EXISTS (
      SELECT 1 FROM system_alerts sa
      WHERE sa.alert_type = 'stale_heartbeat'
        AND sa.message LIKE '%' || h.job_name || '%'
        AND sa.created_at > now() - h.expected_interval
    );
  $$
);
