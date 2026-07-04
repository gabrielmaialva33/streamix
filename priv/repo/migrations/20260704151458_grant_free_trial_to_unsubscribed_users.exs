defmodule Streamix.Repo.Migrations.GrantFreeTrialToUnsubscribedUsers do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO plans (
      name,
      slug,
      description,
      price_cents,
      currency,
      billing_interval,
      trial_days,
      active,
      grants_global_access,
      inserted_at,
      updated_at
    )
    VALUES (
      'Free Trial',
      'free-trial',
      '7 dias grátis para testar o catálogo global',
      0,
      'USD',
      'month',
      7,
      true,
      true,
      date_trunc('second', now()),
      date_trunc('second', now())
    )
    ON CONFLICT (slug) DO UPDATE SET
      active = true,
      grants_global_access = true,
      trial_days = GREATEST(plans.trial_days, 7),
      updated_at = date_trunc('second', now())
    """)

    execute("""
    INSERT INTO plan_features (
      plan_id,
      feature,
      enabled,
      "limit",
      metadata,
      inserted_at,
      updated_at
    )
    SELECT
      p.id,
      feature_data.feature,
      feature_data.enabled,
      feature_data."limit",
      '{}'::jsonb,
      date_trunc('second', now()),
      date_trunc('second', now())
    FROM plans p
    CROSS JOIN (
      VALUES
        ('global_catalog', true, NULL::integer),
        ('max_providers', true, 1),
        ('concurrent_streams', true, 1),
        ('ai_recommendations', false, NULL::integer),
        ('watch_party', false, NULL::integer)
    ) AS feature_data(feature, enabled, "limit")
    WHERE p.slug = 'free-trial'
    ON CONFLICT (plan_id, feature) DO UPDATE SET
      enabled = EXCLUDED.enabled,
      "limit" = EXCLUDED."limit",
      updated_at = date_trunc('second', now())
    """)

    execute("""
    INSERT INTO subscriptions (
      user_id,
      plan_id,
      status,
      starts_at,
      expires_at,
      source,
      external_reference,
      inserted_at,
      updated_at
    )
    SELECT
      u.id,
      p.id,
      'active',
      date_trunc('second', now()),
      date_trunc('second', now()) + (p.trial_days || ' days')::interval,
      'trial',
      'trial:signup:' || u.id,
      date_trunc('second', now()),
      date_trunc('second', now())
    FROM users u
    CROSS JOIN plans p
    WHERE p.slug = 'free-trial'
      AND p.active = true
      AND NOT EXISTS (
        SELECT 1
        FROM subscriptions existing
        JOIN plans existing_plan ON existing_plan.id = existing.plan_id
        WHERE existing.user_id = u.id
          AND existing.status = 'active'
          AND (existing.starts_at IS NULL OR existing.starts_at <= now())
          AND (existing.expires_at IS NULL OR existing.expires_at > now())
          AND (
            existing_plan.grants_global_access = true
            OR EXISTS (
              SELECT 1
              FROM plan_features feature
              WHERE feature.plan_id = existing_plan.id
                AND feature.feature = 'global_catalog'
                AND feature.enabled = true
            )
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM subscriptions signup_trial
        WHERE signup_trial.external_reference = 'trial:signup:' || u.id
      )
    """)
  end

  def down do
    execute("""
    DELETE FROM subscriptions
    WHERE source = 'trial'
      AND external_reference LIKE 'trial:signup:%'
    """)
  end
end
