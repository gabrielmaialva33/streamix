defmodule StreamixWeb.HomeCatalogLoader do
  @moduledoc """
  Parallel loader for the home page's 8 catalog sections.

  Each fetcher runs in its own task. A crash or timeout in one section
  must **not** take down the whole mount: the original implementation
  did an `exit(reason)` on the first `{:exit, _}`, which killed the
  LiveView process and caused a reconnect loop whenever, say, a single
  `trending` query hit the 15s timeout — the user perceived this as
  "page takes forever to load on first visit". Now a failing section
  resolves to an empty payload (`[]` or `nil`) and the other seven
  still render.

  The loader keeps its original key-preserving contract; callers can
  still match against `sections.trending`, `sections.featured`, etc.
  """

  require Logger

  @default_timeout 15_000

  # What we substitute into a failed section's slot. Chosen so the
  # templates that iterate (`for x <- @trending`) just render nothing
  # instead of crashing on a missing key, and the ones that do a
  # `@featured && ...` existence check still short-circuit cleanly.
  @fallbacks %{
    featured: nil,
    stats: %{},
    trending: [],
    new_releases: [],
    top_10: [],
    movies: [],
    series: [],
    channels: [],
    favorites: [],
    history: [],
    recommendations: [],
    featured_favorite: false,
    movie_favorites_map: MapSet.new(),
    series_favorites_map: MapSet.new(),
    movie_progress: %{},
    series_progress: %{},
    genre_filters: []
  }

  @spec load(%{required(term()) => (-> term())} | keyword((-> term())), keyword()) :: map()
  def load(fetchers, opts \\ []) do
    fetchers = Enum.to_list(fetchers)
    # Cap concurrency at scheduler count. With 8 sections fanned out on a
    # 4-core node we were thrashing the BEAM scheduler — and the ones
    # racing for the same ConCache lock (`user_profile:USER_ID`) made it
    # worse, not better, because they piled up on the lock and timed out.
    # Honor an explicit opt when a caller has a different need.
    default_concurrency = min(length(fetchers), System.schedulers_online())
    max_concurrency = Keyword.get(opts, :max_concurrency, default_concurrency)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # `zip_with` on `async_stream` gives us back the original key even
    # when the task exits — ordered output on failure is what lets us
    # tell *which* section timed out.
    fetchers
    |> Task.async_stream(fn {key, fun} -> {key, safe_call(key, fun)} end,
      ordered: true,
      timeout: timeout,
      on_timeout: :kill_task,
      max_concurrency: max_concurrency
    )
    |> Enum.zip(fetchers)
    |> Enum.reduce(%{}, fn
      {{:ok, {key, value}}, _}, acc ->
        Map.put(acc, key, value)

      {{:exit, reason}, {key, _}}, acc ->
        Logger.warning(
          "[HomeCatalogLoader] section #{inspect(key)} timed out/crashed: #{inspect(reason)}"
        )

        Map.put(acc, key, fallback_for(key))
    end)
  end

  # Isolate individual fetcher exceptions so a bad section doesn't
  # surface as `{:exit, :killed}` on the async_stream (which is
  # indistinguishable from a real timeout). Caught exceptions log the
  # stacktrace and the caller gets the fallback.
  defp safe_call(key, fun) do
    fun.()
  rescue
    e ->
      Logger.warning(
        "[HomeCatalogLoader] section #{inspect(key)} raised: #{Exception.message(e)}"
      )

      fallback_for(key)
  end

  defp fallback_for(key), do: Map.get(@fallbacks, key, [])
end
