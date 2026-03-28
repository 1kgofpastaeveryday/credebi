-- Subscription lifecycle status
-- Replaces boolean is_active with a richer state model.
-- is_active is kept as a computed equivalent: status != 'cancelled'

ALTER TABLE subscriptions
  ADD COLUMN status TEXT DEFAULT 'confirmed'
    CHECK (status IN ('pending_confirm', 'confirmed', 'payment_pending', 'cancelled'));

-- Backfill: existing active → confirmed, inactive → cancelled
UPDATE subscriptions SET status = CASE WHEN is_active THEN 'confirmed' ELSE 'cancelled' END;

-- cancelled_at for audit trail (DT-078)
ALTER TABLE subscriptions
  ADD COLUMN cancelled_at TIMESTAMPTZ;

COMMENT ON COLUMN subscriptions.status IS
  'pending_confirm: auto-detected, awaiting user confirmation. confirmed: user-verified or manual. payment_pending: past next_billing_at by 7+ days, charge unconfirmed. cancelled: 30+ days no charge, user cancelled, or cancellation email detected.';
