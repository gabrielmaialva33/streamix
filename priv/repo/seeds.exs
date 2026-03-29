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

alias Streamix.{Accounts, Access, Billing, Iptv}

# Create admin user from env vars
admin_email = env["ADMIN_EMAIL"] || "admin@streamix.local"
admin_password = env["ADMIN_PASSWORD"]

unless admin_password do
  raise "ADMIN_PASSWORD environment variable is required for seeding"
end

admin = Accounts.ensure_admin_user!(admin_email, admin_password)
IO.puts("✓ Admin user ready: #{admin.email} (role=#{admin.role})")

default_plan =
  Billing.ensure_plan!(%{
    name: "Default",
    slug: "default",
    description: "Default active plan",
    price_cents: 0,
    currency: "USD",
    billing_interval: "month",
    active: true,
    grants_global_access: false
  })

premium_plan =
  Billing.ensure_plan!(%{
    name: "Premium",
    slug: "premium",
    description: "Premium plan with global access",
    price_cents: 1_999,
    currency: "USD",
    billing_interval: "month",
    active: true,
    grants_global_access: true
  })

IO.puts("✓ Billing plans ready: #{default_plan.slug}, #{premium_plan.slug}")

global_permission =
  Access.ensure_permission!(%{
    name: "play_global_content",
    description: "Allows playing global content"
  })

Access.ensure_role_permission!("admin", global_permission)
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
    case Enum.find([default_plan, premium_plan], &(&1.slug == plan_slug)) do
      nil ->
        raise(
          "SEED_SUBSCRIPTION_PLAN_SLUG must match one of the seeded plans: #{default_plan.slug}, #{premium_plan.slug}"
        )

      plan ->
        plan
    end

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
    Iptv.list_providers(admin.id)
    |> Enum.find(&(&1.name == provider_name))

  if existing_provider do
    IO.puts("→ Provider already exists: #{provider_name}")
  else
    {:ok, provider} =
      Iptv.create_provider(%{
        name: provider_name,
        url: provider_url,
        username: provider_username,
        password: provider_password,
        user_id: admin.id
      })

    IO.puts("✓ Created provider: #{provider_name}")

    # Sync channels
    IO.puts("⏳ Syncing channels from #{provider_name}...")

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
  case GlobalProvider.ensure_exists!() do
    {:ok, provider} when is_struct(provider) ->
      IO.puts("✓ Global provider ready: #{provider.name}")

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
