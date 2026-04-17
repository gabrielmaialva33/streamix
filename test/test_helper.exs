# Exclude integration, slow and playwright tests by default
# Run with: mix test --include integration --include slow --include playwright
ExUnit.start(exclude: [:integration, :slow, :playwright])
Ecto.Adapters.SQL.Sandbox.mode(Streamix.Repo, :manual)

# Start Playwright supervisor only when explicitly running :playwright tests
if :playwright in (ExUnit.configuration()[:include] || []) do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, StreamixWeb.Endpoint.url())
end
