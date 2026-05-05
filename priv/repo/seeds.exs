# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Streamix.Repo.insert!(%Streamix.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Load .env file - returns a merged map of env vars
env = Dotenvy.source!([".env", System.get_env()])

# Configure global provider from env (runtime.exs was already evaluated)
if env["GLOBAL_PROVIDER_ENABLED"] == "true" do
  Application.put_env(:streamix, :global_provider,
    enabled: true,
    name: env["GLOBAL_PROVIDER_NAME"] || "Streamix Global",
    url: env["GLOBAL_PROVIDER_URL"],
    username: env["GLOBAL_PROVIDER_USERNAME"],
    password: env["GLOBAL_PROVIDER_PASSWORD"]
  )
end

alias Streamix.{Access, Accounts, Billing, Iptv, Repo}
alias Streamix.Iptv.Provider

# Create admin user from env vars
admin_email = env["ADMIN_EMAIL"] || "admin@streamix.local"
admin_password = env["ADMIN_PASSWORD"]

unless admin_password do
  raise "ADMIN_PASSWORD environment variable is required for seeding"
end

admin = Accounts.ensure_admin_user!(admin_email, admin_password)
IO.puts("✓ Admin user ready: #{admin.email} (role=#{Accounts.role_name(admin)})")

basic_plan =
  Billing.ensure_plan!(%{
    name: "Basic Mensal",
    slug: "basic-monthly",
    description: "Plano de entrada para catálogo próprio",
    price_cents: 999,
    currency: "USD",
    billing_interval: "month",
    active: true,
    grants_global_access: false,
    features: %{
      global_catalog: false,
      max_providers: 1,
      concurrent_streams: 1,
      ai_recommendations: false,
      watch_party: false
    }
  })

premium_plan =
  Billing.ensure_plan!(%{
    name: "Premium Mensal",
    slug: "premium-monthly",
    description: "Catálogo global, AI premium e mais providers",
    price_cents: 1_999,
    currency: "USD",
    billing_interval: "month",
    active: true,
    grants_global_access: true,
    features: %{
      global_catalog: true,
      max_providers: 3,
      concurrent_streams: 2,
      ai_recommendations: true,
      watch_party: true
    }
  })

ultimate_plan =
  Billing.ensure_plan!(%{
    name: "Ultimate Mensal",
    slug: "ultimate-monthly",
    description: "Mais telas simultâneas e mais providers",
    price_cents: 2_999,
    currency: "USD",
    billing_interval: "month",
    active: true,
    grants_global_access: true,
    features: %{
      global_catalog: true,
      max_providers: 10,
      concurrent_streams: 4,
      ai_recommendations: true,
      watch_party: true
    }
  })

seeded_plans = [basic_plan, premium_plan, ultimate_plan]

IO.puts("✓ Billing plans ready: #{Enum.map_join(seeded_plans, ", ", & &1.slug)}")

global_permission = Access.ensure_permission!("play_global_content")

Access.ensure_role_permissions!("admin", [global_permission.name])
IO.puts("✓ Permission ready: #{global_permission.name} (linked to admin)")

parse_datetime = fn
  nil ->
    nil

  "" ->
    nil

  value ->
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, reason} ->
        raise "Invalid SEED_SUBSCRIPTION_EXPIRES_AT value #{inspect(value)}: #{inspect(reason)}"
    end
end

# Create a manual subscription only when explicitly requested.
subscription_email = env["SEED_SUBSCRIPTION_EMAIL"]

if subscription_email do
  plan_slug = env["SEED_SUBSCRIPTION_PLAN_SLUG"] || premium_plan.slug

  subscription_plan =
    Enum.find(seeded_plans, &(&1.slug == plan_slug)) ||
      raise("SEED_SUBSCRIPTION_PLAN_SLUG must match a seeded plan: #{plan_slug}")

  subscription_user =
    case Accounts.get_user_by_email(subscription_email) do
      nil ->
        raise("SEED_SUBSCRIPTION_EMAIL must match an existing user: #{subscription_email}")

      user ->
        user
    end

  Billing.ensure_manual_subscription!(subscription_user, subscription_plan, %{
    status: "active",
    source: "manual",
    external_reference: "seed:manual:#{subscription_user.id}:#{subscription_plan.id}",
    starts_at: DateTime.utc_now() |> DateTime.truncate(:second),
    expires_at: parse_datetime.(env["SEED_SUBSCRIPTION_EXPIRES_AT"])
  })

  IO.puts(
    "✓ Manual subscription ready for #{subscription_user.email} on #{subscription_plan.slug}"
  )
else
  IO.puts("→ Skipping manual subscription (SEED_SUBSCRIPTION_EMAIL not set)")
end

# Create default IPTV provider from env vars (if configured)
provider_name = env["IPTV_PROVIDER_NAME"]
provider_url = env["IPTV_PROVIDER_URL"]
provider_username = env["IPTV_USERNAME"]
provider_password = env["IPTV_PASSWORD"]

if provider_name && provider_url && provider_username && provider_password do
  existing_provider =
    Repo.get_by(Provider,
      provider_type: :xtream,
      is_system: false,
      url: provider_url,
      username: provider_username
    ) ||
      Iptv.list_providers(admin.id)
      |> Enum.find(&(&1.name == provider_name))

  provider_attrs = %{
    name: provider_name,
    url: provider_url,
    username: provider_username,
    password: provider_password,
    is_active: true
  }

  provider =
    if existing_provider do
      existing_provider
      |> Provider.changeset(provider_attrs)
      |> Ecto.Changeset.put_change(:user_id, admin.id)
      |> Repo.update!()
    else
      {:ok, provider} =
        Iptv.create_provider(admin.id, %{
          name: provider_name,
          url: provider_url,
          username: provider_username,
          password: provider_password
        })

      provider
    end

  IO.puts("✓ Provider ready: #{provider.name} (owner=#{admin.email})")

  if is_nil(existing_provider) do
    # Sync channels
    IO.puts("⏳ Syncing channels from #{provider.name}...")

    case Iptv.sync_provider(provider) do
      {:ok, count} ->
        IO.puts("✓ Synced #{count} channels")

      {:error, reason} ->
        IO.puts("✗ Failed to sync: #{inspect(reason)}")
    end
  end
else
  IO.puts("→ Skipping IPTV provider (env vars not configured)")
end

# Create global provider (if configured)
alias Streamix.Iptv.GlobalProvider

if GlobalProvider.enabled?() do
  case GlobalProvider.ensure_exists!(admin) do
    {:ok, provider} when is_struct(provider) ->
      IO.puts("✓ Global provider ready: #{provider.name} (owner=#{admin.email})")

      # Sync global provider content
      IO.puts("⏳ Syncing global provider content...")

      case GlobalProvider.sync!() do
        {:ok, stats} ->
          IO.puts(
            "✓ Synced global provider - Live: #{stats.live}, Movies: #{stats.movies}, Series: #{stats.series}"
          )

        {:error, reason} ->
          IO.puts("✗ Failed to sync global provider: #{inspect(reason)}")
      end

    {:error, changeset} ->
      IO.puts("✗ Failed to create global provider: #{inspect(changeset.errors)}")
  end
else
  IO.puts("→ Global provider not configured (set GLOBAL_PROVIDER_ENABLED=true)")
end
