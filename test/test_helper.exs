# Exclude integration and slow tests by default
# Run with: mix test --include integration --include slow
ExUnit.start(exclude: [:integration, :slow])
Ecto.Adapters.SQL.Sandbox.mode(Streamix.Repo, :manual)
