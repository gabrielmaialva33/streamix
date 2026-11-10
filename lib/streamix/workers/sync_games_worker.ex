defmodule Streamix.Workers.SyncGamesWorker do
  @moduledoc "Dispatches opted-in sports feeds every ten minutes and syncs each provider independently."
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [
      period: 600,
      keys: [:provider_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Streamix.{Providers, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_id" => id}}) do
    case Providers.get_provider(id) do
      %{games_enabled: true, is_active: true, provider_type: :xtream} = provider ->
        case Providers.sync_games(provider) do
          {:ok, _count} ->
            :ok

          # The next dispatch is ten minutes away. Retrying sooner only
          # repeats the same timeouts (a feed walks every provider URL, up to
          # 20 s each) while holding a slot of the `sync` queue that provider
          # syncs need.
          {:error, _reason} ->
            {:cancel, :games_unavailable}
        end

      _ ->
        :ok
    end
  end

  def perform(%Oban.Job{}) do
    Providers.prune_games()
    jobs = Enum.map(Providers.games_providers(), &new(%{provider_id: &1.id}))
    Repo.transaction(fn -> Enum.each(jobs, &Oban.insert!/1) end)
    :ok
  end
end
