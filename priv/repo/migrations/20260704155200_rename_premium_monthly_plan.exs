defmodule Streamix.Repo.Migrations.RenamePremiumMonthlyPlan do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE plans
    SET
      name = 'Global Mensal',
      description = 'Catálogo global, AI avançada e mais providers',
      updated_at = now()
    WHERE slug = 'premium-monthly'
    """)
  end

  def down do
    execute("""
    UPDATE plans
    SET
      name = 'Premium Mensal',
      description = 'Catálogo global, AI premium e mais providers',
      updated_at = now()
    WHERE slug = 'premium-monthly'
    """)
  end
end
