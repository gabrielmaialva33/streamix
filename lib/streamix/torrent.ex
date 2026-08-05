defmodule Streamix.Torrent do
  @moduledoc """
  Public facade for torrent ingestion and playback.

  Mirrors `Streamix.Gindex` in shape: this module is the single
  entrypoint outside the `Streamix.Torrent.*` namespace, so the
  worker layer and any future LiveViews/controllers don't reach into
  internal sync modules directly.
  """

  alias Streamix.Iptv
  alias Streamix.Repo
  alias Streamix.Torrent.{Catalog, Client, Config, Sources, StreamSession, Sync, TorrentStream}

  @ready_bytes 5_000_000

  defdelegate sync_provider(provider), to: Sync
  defdelegate sync_source(provider, source_module, opts \\ []), to: Sync
  defdelegate refresh_provider_counts(provider, opts \\ []), to: Sync

  # Catalog read model (powers the dedicated torrent screen).
  defdelegate provider(), to: Catalog
  defdelegate list_movies(opts \\ []), to: Catalog
  defdelegate count_movies(opts \\ []), to: Catalog
  defdelegate streams_for_movie(movie_id), to: Catalog
  defdelegate best_stream_for_movie(movie_id), to: Catalog

  @doc "Returns whether the torrent engine is enabled in runtime configuration."
  defdelegate enabled?(), to: Config

  @doc """
  Lists the configured torrent sources.
  """
  defdelegate sources(), to: Sources, as: :list

  @doc """
  Looks up a source module by its slug, or returns `nil`.
  """
  defdelegate source_for(slug), to: Sources, as: :fetch

  @spec get_stream_by_hash(String.t()) :: TorrentStream.t() | :not_found
  def get_stream_by_hash(info_hash) when is_binary(info_hash) do
    Repo.get_by(TorrentStream, info_hash: String.downcase(info_hash)) || :not_found
  end

  def get_stream_by_hash(_info_hash), do: :not_found

  @doc """
  Loads a torrent stream together with the movie and provider needed by playback.
  """
  def get_stream_for_playback(id) do
    with %TorrentStream{movie_id: movie_id} = stream when is_integer(movie_id) <-
           Repo.get(TorrentStream, id),
         {:ok, movie, provider} <- Iptv.get_torrent_movie_for_playback(movie_id) do
      {:ok, stream, movie, provider}
    else
      _ -> :not_found
    end
  end

  defdelegate start_or_join(info_hash, magnet_uri, viewer_pid), to: StreamSession
  defdelegate leave(info_hash, viewer_pid), to: StreamSession
  defdelegate retry(info_hash), to: StreamSession
  defdelegate stream_url(info_hash, file_idx), to: Client
  defdelegate auth_headers(), to: Client

  @doc """
  Returns a browser-safe snapshot for one torrent.

  The state vocabulary is owned here rather than leaking rqbit's raw
  strings into the UI: `absent`, `connecting`, `buffering`, `ready`,
  `degraded`, or `failed`.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, map()}
  def status(info_hash) when is_binary(info_hash) do
    case Client.stats(info_hash) do
      {:ok, stats} ->
        {:ok, status_payload(info_hash, stats)}

      {:error, :not_found} ->
        {:ok, session_payload(info_hash, StreamSession.snapshot(info_hash))}

      {:error, reason} ->
        {:error,
         base_payload(info_hash, "degraded")
         |> Map.merge(%{
           failure_code: classify_failure(reason),
           message: "Motor torrent temporariamente indisponível.",
           retryable: true
         })}
    end
  end

  @doc "Small rqbit health snapshot for the operations dashboard."
  @spec health() :: map()
  def health do
    if Config.enabled?() do
      case Client.list() do
        {:ok, torrents} ->
          %{status: :healthy, active_torrents: length(torrents), message: "rqbit respondendo"}

        {:error, reason} ->
          %{
            status: :unhealthy,
            active_torrents: 0,
            message: "rqbit indisponível",
            failure_code: classify_failure(reason)
          }
      end
    else
      %{status: :disabled, active_torrents: 0, message: "torrent desativado"}
    end
  end

  defp status_payload(info_hash, stats) do
    state =
      cond do
        stats.finished -> "ready"
        stats.state == "live" and stats.progress_bytes >= @ready_bytes -> "ready"
        stats.state == "live" -> "buffering"
        true -> "connecting"
      end

    base_payload(info_hash, state)
    |> Map.merge(%{
      progress_bytes: stats.progress_bytes,
      total_bytes: stats.total_bytes,
      finished: stats.finished,
      live_peers: stats.live_peers,
      download_speed_bps: stats.download_speed_bps,
      retryable: state != "ready"
    })
  end

  defp session_payload(info_hash, nil), do: base_payload(info_hash, "absent")

  defp session_payload(info_hash, snapshot) do
    state =
      case snapshot.stage do
        :connecting -> "connecting"
        :buffering -> "buffering"
        :degraded -> "degraded"
        :ready -> "ready"
        :failed -> "failed"
        _ -> "connecting"
      end

    base_payload(info_hash, state)
    |> Map.merge(%{
      failure_code: snapshot.failure_code,
      message: session_message(state),
      retryable: state in ["degraded", "failed"]
    })
  end

  defp base_payload(info_hash, state) do
    %{
      info_hash: String.downcase(info_hash),
      state: state,
      progress_bytes: 0,
      total_bytes: 0,
      finished: false,
      live_peers: 0,
      download_speed_bps: 0,
      failure_code: nil,
      message: session_message(state),
      retryable: false
    }
  end

  defp session_message("absent"), do: "Preparando o swarm."
  defp session_message("connecting"), do: "Conectando ao motor torrent."
  defp session_message("buffering"), do: "Carregando dados iniciais."
  defp session_message("ready"), do: "Torrent pronto."
  defp session_message("degraded"), do: "Motor torrent instável; tentando novamente."
  defp session_message("failed"), do: "Não foi possível iniciar o torrent."
  defp session_message(_), do: "Preparando o torrent."

  defp classify_failure({:transport_error, _reason}), do: "engine_unavailable"
  defp classify_failure({:http_error, status, _body}) when status in 500..599, do: "engine_5xx"
  defp classify_failure(_reason), do: "engine_error"
end
