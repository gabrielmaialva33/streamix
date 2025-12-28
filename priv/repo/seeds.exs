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

alias Streamix.{Accounts, Iptv}

# Create admin user from env vars
admin_email = env["ADMIN_EMAIL"] || "admin@streamix.local"
admin_password = env["ADMIN_PASSWORD"] || "changeme12345"

admin =
  case Accounts.get_user_by_email(admin_email) do
    nil ->
      {:ok, user} =
        Accounts.register_user_with_password(%{email: admin_email, password: admin_password})

      IO.puts("✓ Created admin user: #{admin_email}")
      user

    user ->
      IO.puts("→ Admin user already exists: #{admin_email}")
      user
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
