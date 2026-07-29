# Exclude integration, slow and playwright tests by default
# Run with: mix test --include integration --include slow --include playwright
max_cases =
  case System.get_env("TEST_MAX_CASES") do
    configured when is_binary(configured) and configured != "" ->
      String.to_integer(configured)

    _ ->
      System.schedulers_online()
  end

ExUnit.start(exclude: [:integration, :slow, :playwright], max_cases: max_cases)
Ecto.Adapters.SQL.Sandbox.mode(Streamix.Repo, :manual)

# Start Playwright supervisor only when explicitly running :playwright tests
if :playwright in (ExUnit.configuration()[:include] || []) do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, StreamixWeb.Endpoint.url())
end
