defmodule Streamix.Iptv.Gindex.MetadataProbe do
  @moduledoc """
  Probes audio + subtitle tracks of a GIndex VOD file by streaming the
  first ~2 MB through ffprobe and parsing the JSON output.

  The web frontend used to instantiate a second `@libmedia/avplayer`
  instance just to enumerate tracks for "Dual Audio" auto-switch on
  Drive content — that cost ~1 s wall time, ~5 MB of WASM and a full
  Web Audio context per probe. Moving the work server-side gives us:

    * one-time cost per file (cached forever in `track_metadata` jsonb)
    * zero client-side overhead on the hot path
    * no extra JS bundle — replaces ~150 LoC of probe logic with a
      single `fetch()`

  This module is GIndex-specific: Choki/Xtream catalog content has
  hls.js / mpegts.js exposing tracks at runtime, so we never call this
  for those.
  """

  require Logger

  alias Streamix.Iptv.{Episode, Movie}
  alias Streamix.Iptv.Gindex
  alias Streamix.Repo

  # Cap how much of the file we feed to ffprobe. For MP4 the moov box
  # is at the start in 99 % of web-optimized files; for MKV the seek
  # head + tracks element live in the first few MB. 2 MB is the sweet
  # spot — small enough to be fast on Drive (~200 ms over the source
  # proxy) yet wide enough to cover both containers.
  @probe_bytes 2 * 1024 * 1024

  @ffprobe_args [
    "-v",
    "error",
    "-show_streams",
    "-show_format",
    "-of",
    "json",
    "-i",
    "pipe:0"
  ]

  @doc """
  Returns cached `track_metadata` immediately if present.

  On cache miss, kicks off the ffprobe pipeline in a detached `Task`
  and returns `{:error, :probing}` right away. The endpoint translates
  that to a 404 — the frontend silently keeps native playback running,
  and the next visitor (or the same user on a reload) hits a populated
  cache.

  This avoids stalling the request behind a slow GIndex URL resolve
  (which can take longer than Cloudflare's 30 s edge timeout).
  """
  @spec fetch(:movie | :episode, integer()) ::
          {:ok, map()} | {:error, term()}
  def fetch(:movie, id), do: do_fetch(Movie, id, &Gindex.get_movie_url/1)
  def fetch(:episode, id), do: do_fetch(Episode, id, &Gindex.get_episode_url/1)
  def fetch(_, _), do: {:error, :unsupported_type}

  defp do_fetch(schema, id, url_fn) do
    with {:ok, row} <- load_row(schema, id) do
      cached_or_schedule(row, url_fn)
    end
  end

  defp cached_or_schedule(row, url_fn) do
    case row.track_metadata do
      %{} = cached when map_size(cached) > 0 -> {:ok, normalize(cached)}
      _ -> kick_off_probe(row, url_fn)
    end
  end

  defp kick_off_probe(row, url_fn) do
    if gindex?(row) do
      schedule_probe(row, url_fn)
      {:error, :probing}
    else
      {:error, :not_gindex}
    end
  end

  defp schedule_probe(row, url_fn) do
    # Fire-and-forget — the request returns immediately, the probe
    # runs in a detached Task and persists when (if) it finishes.
    Task.Supervisor.start_child(Streamix.TaskSupervisor, fn ->
      with {:ok, url} <- resolve_url(row, url_fn),
           {:ok, json} <- run_probe(url),
           {:ok, tracks} <- parse_tracks(json) do
        persist(row, tracks)
      else
        err -> Logger.warning("MetadataProbe background failed: #{inspect(err)}")
      end
    end)
  end

  defp load_row(schema, id) do
    case Repo.get(schema, id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  defp gindex?(%{gindex_path: path}) when is_binary(path) and path != "", do: true
  defp gindex?(_), do: false

  defp resolve_url(%Movie{id: id}, url_fn), do: invoke_url_fn(url_fn, id)
  defp resolve_url(%Episode{id: id}, url_fn), do: invoke_url_fn(url_fn, id)

  defp invoke_url_fn(url_fn, id) do
    case url_fn.(id) do
      {:ok, url} when is_binary(url) -> {:ok, url}
      {:error, reason} -> {:error, {:url_resolve_failed, reason}}
      other -> {:error, {:url_resolve_unexpected, other}}
    end
  end

  defp run_probe(url) do
    with {:ok, body} <- fetch_head_bytes(url),
         {:ok, output} <- pipe_to_ffprobe(body) do
      Jason.decode(output)
    end
  end

  defp fetch_head_bytes(url) do
    headers = [
      {"range", "bytes=0-#{@probe_bytes - 1}"},
      {"user-agent", "Streamix-Probe/1.0"}
    ]

    case Req.get(url, headers: headers, receive_timeout: 30_000, decode_body: false) do
      {:ok, %{status: status, body: body}} when status in [200, 206] ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:probe_fetch_failed, status}}

      {:error, reason} ->
        {:error, {:probe_fetch_error, reason}}
    end
  end

  defp pipe_to_ffprobe(body) do
    port =
      Port.open({:spawn_executable, ffprobe_path()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, @ffprobe_args}
      ])

    Port.command(port, body)

    # Closing stdin tells ffprobe we're done feeding it.
    case :erlang.port_close(port) do
      true -> :ok
      _ -> :ok
    end

    receive do
      {^port, {:data, data}} ->
        receive_remaining(port, [data])

      {^port, {:exit_status, 0}} ->
        {:error, :ffprobe_no_output}

      {^port, {:exit_status, status}} ->
        {:error, {:ffprobe_exit, status}}
    after
      30_000 ->
        {:error, :ffprobe_timeout}
    end
  end

  defp receive_remaining(port, acc) do
    receive do
      {^port, {:data, data}} -> receive_remaining(port, [data | acc])
      {^port, {:exit_status, _}} -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      5_000 ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp ffprobe_path do
    case System.find_executable("ffprobe") do
      nil -> raise "ffprobe binary not found on PATH"
      path -> path
    end
  end

  defp parse_tracks(%{"streams" => streams}) when is_list(streams) do
    audio = streams |> Enum.filter(&(&1["codec_type"] == "audio")) |> Enum.map(&track_summary/1)

    subtitle =
      streams |> Enum.filter(&(&1["codec_type"] == "subtitle")) |> Enum.map(&track_summary/1)

    {:ok,
     %{audio: audio, subtitle: subtitle, probed_at: DateTime.utc_now() |> DateTime.to_iso8601()}}
  end

  defp parse_tracks(_), do: {:error, :ffprobe_unexpected_shape}

  defp track_summary(stream) do
    tags = stream["tags"] || %{}

    %{
      index: stream["index"],
      codec: stream["codec_name"],
      language: tags["language"] || tags["LANGUAGE"] || "und",
      title: tags["title"] || tags["TITLE"],
      channels: stream["channels"],
      default: stream["disposition"]["default"] == 1,
      forced: stream["disposition"]["forced"] == 1
    }
  end

  defp persist(row, tracks) do
    row
    |> Ecto.Changeset.change(track_metadata: tracks)
    |> Repo.update()
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> Logger.warning("MetadataProbe persist failed: #{inspect(changeset)}")
    end
  end

  # When pulled from the DB the keys are strings, but the controller
  # speaks atoms — normalize on read so callers always see the same
  # shape regardless of fresh-vs-cached.
  defp normalize(%{} = m) do
    %{
      audio: Map.get(m, "audio", Map.get(m, :audio, [])),
      subtitle: Map.get(m, "subtitle", Map.get(m, :subtitle, [])),
      probed_at: Map.get(m, "probed_at", Map.get(m, :probed_at))
    }
  end
end
