defmodule Streamix.Embedplay.Canary do
  @moduledoc """
  One health probe: resolves a single Embedplay movie through the resolver and
  feeds the outcome to `Streamix.Embedplay.Health`.

  `Streamix.Workers.EmbedplayCanaryWorker` runs it every 30 minutes and is
  unique while in flight, so a probe never holds more than one of the
  resolver's two browser slots.

  When it actually resolves:

    * degraded — on every tick. Degraded playback fails before reaching the
      resolver, so the probe is the only way back to healthy.
    * healthy — only after `:canary_idle_seconds` (default one hour) without
      any observed resolution. Real playback is a better probe and costs
      nothing extra; the canary covers quiet periods so a breakage is still
      caught when nobody is watching, and the first tick after a deploy (the
      window starts empty) re-establishes the truth.

  It calls the resolver directly rather than through the session cache: a
  cached resolution from before a breakage must not count as proof that
  resolution works now.
  """

  require Logger

  alias Streamix.{Catalog, Embedplay, Providers}
  alias Streamix.Embedplay.{Health, HTTP}

  @idle_seconds 3_600

  @type result :: {:ok, :success | {:failure, atom()}} | {:skip, atom()}

  @doc """
  Probes once if a probe is due. `opts` are passed to `Health` (`:server`).
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    with {:ok, provider} <- provider(),
         :ok <- due(provider, opts),
         {:ok, movie} <- pick_movie(provider, opts) do
      result = HTTP.resolve(movie)

      Health.observe(
        movie.id,
        result,
        Keyword.merge(opts, source: :canary, recover: provider.health_status == :degraded)
      )

      outcome = outcome(result)

      Logger.info(
        "[Embedplay] canary probe movie_id=#{movie.id} " <>
          "health=#{provider.health_status} outcome=#{inspect(outcome)}"
      )

      {:ok, outcome}
    end
  end

  defp provider do
    if Embedplay.enabled?() do
      case Providers.get_embedplay_provider() do
        %{is_active: true} = provider -> {:ok, provider}
        nil -> {:skip, :no_provider}
        _inactive -> {:skip, :provider_inactive}
      end
    else
      {:skip, :embedplay_disabled}
    end
  end

  defp due(%{health_status: :degraded}, _opts), do: :ok

  defp due(_provider, opts) do
    idle_seconds = Embedplay.config(:canary_idle_seconds, @idle_seconds)

    case Health.summary(opts) do
      %{seconds_since_last_outcome: seconds}
      when is_integer(seconds) and seconds < idle_seconds ->
        {:skip, :recent_traffic}

      _idle ->
        :ok
    end
  end

  # Titles that just failed are skipped so successive probes cover distinct
  # movies; with nothing else left, any title will do.
  defp pick_movie(provider, opts) do
    failing = opts |> Health.failing_movie_ids() |> Enum.filter(&is_integer/1)

    case Catalog.embedplay_canary_movie(provider.id, failing) ||
           Catalog.embedplay_canary_movie(provider.id) do
      nil -> {:skip, :no_movies}
      movie -> {:ok, movie}
    end
  end

  defp outcome({:ok, _source}), do: :success
  defp outcome({:error, reason}), do: {:failure, reason}
end
