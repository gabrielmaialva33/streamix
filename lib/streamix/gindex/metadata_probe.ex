defmodule Streamix.Gindex.MetadataProbe do
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

  alias Streamix.Gindex

  # Cap how much of the file we feed to ffprobe. For MP4 the moov box
  # is at the start in 99 % of web-optimized files; for MKV the seek
  # head + tracks element live in the first few MB. 2 MB is the sweet
  # spot — small enough to be fast on Drive (~200 ms over the source
  # proxy) yet wide enough to cover both containers.
  @probe_bytes 2 * 1024 * 1024

  @ffprobe_base_args [
    "-v",
    "error",
    "-show_streams",
    "-show_format",
    "-of",
    "json",
    "-i"
  ]

  @ffprobe_environment_variables ~w(LANG LC_ALL LC_CTYPE LD_LIBRARY_PATH PATH TMPDIR TZ)

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
  def fetch(:movie, id), do: do_fetch(:movie, id, &Gindex.get_movie_url/1)
  def fetch(:episode, id), do: do_fetch(:episode, id, &Gindex.get_episode_url/1)
  def fetch(_, _), do: {:error, :unsupported_type}

  defp do_fetch(type, id, url_fn) do
    with {:ok, source} <- Streamix.Catalog.get_media_track_source(type, id) do
      cached_or_schedule(type, source, url_fn)
    end
  end

  defp cached_or_schedule(type, source, url_fn) do
    case source.track_metadata do
      %{} = cached when map_size(cached) > 0 -> {:ok, normalize(cached)}
      _empty -> kick_off_probe(type, source, url_fn)
    end
  end

  defp kick_off_probe(type, source, url_fn) do
    if gindex?(source) do
      schedule_probe(type, source, url_fn)
      {:error, :probing}
    else
      {:error, :not_gindex}
    end
  end

  defp schedule_probe(type, source, url_fn) do
    # Fire-and-forget — the request returns immediately, the probe
    # runs in a detached Task and persists when (if) it finishes.
    Task.Supervisor.start_child(Streamix.TaskSupervisor, fn ->
      with {:ok, url} <- resolve_url(source, url_fn),
           {:ok, json} <- run_probe(url),
           {:ok, tracks} <- parse_tracks(json) do
        persist(type, source.id, tracks)
      else
        err -> Logger.warning("MetadataProbe background failed: #{inspect(err)}")
      end
    end)
  end

  defp gindex?(%{gindex_path: path}) when is_binary(path) and path != "", do: true
  defp gindex?(_), do: false

  defp resolve_url(%{id: id}, url_fn), do: invoke_url_fn(url_fn, id)

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
    # Spool the bytes to a tempfile and let ffprobe read it via path.
    # Stdin pipes are tricky here: closing stdin ahead of time kills the
    # port (Erlang's port_close terminates the process), and leaving it
    # open hangs ffprobe waiting for more bytes. A temp file dodges
    # both — we delete it as soon as the System.cmd returns.
    tmp =
      Path.join(System.tmp_dir!(), "streamix_probe_#{:erlang.unique_integer([:positive])}.bin")

    try do
      :ok = File.write(tmp, body)

      case System.cmd(ffprobe_path(), @ffprobe_base_args ++ [tmp],
             env: ffprobe_environment(),
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          {:ok, output}

        {output, status} ->
          {:error, {:ffprobe_exit, status, output}}
      end
    after
      File.rm(tmp)
    end
  end

  defp ffprobe_path do
    case System.find_executable("ffprobe") do
      nil -> raise "ffprobe binary not found on PATH"
      path -> path
    end
  end

  defp ffprobe_environment do
    System.get_env()
    |> Map.new(fn {name, value} ->
      {name, if(name in @ffprobe_environment_variables, do: value, else: nil)}
    end)
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
    disposition = stream["disposition"] || %{}

    %{
      index: stream["index"],
      codec: stream["codec_name"],
      language: tags["language"] || tags["LANGUAGE"] || "und",
      title: sanitize_title(tags["title"] || tags["TITLE"]),
      channels: stream["channels"],
      default: disposition["default"] == 1,
      forced: disposition["forced"] == 1
    }
  end

  # Release groups stamp their watermark into the container's track title, and
  # the web player renders that title as the track's label. Every distinct
  # title in the catalog carries one:
  #
  #     COMANDO.TO   LAPUMiA   LAPUMiAFiLMES.COM   WWW.BLUDV.COM
  #     WWW.BLUDV.COM 5.1 [BR]   Inglês 5.1 - LAPUMiA   Português 2.0 - LAPUMiA
  #
  # Dropping the whole title on a watermark would also throw away the last two,
  # which are the only genuinely useful labels in the set. So strip the
  # watermark and keep what survives.
  #
  # The group list is short and specific on purpose: these are the groups this
  # catalog actually carries. A bare group name has no generic signature that
  # separates it from a real track title, so guessing would cost more than it
  # buys.
  @title_watermarks [
    ~r/\bwww\.\S+/i,
    ~r/\b[\w-]+\.(?:com|net|org|to|tv|me|cc)\b/i,
    ~r/\bLAPUMiA\w*/i,
    ~r/\bBLUDV\w*/i,
    ~r/\bCOMANDO\w*/i
  ]

  defp sanitize_title(nil), do: nil

  defp sanitize_title(title) when is_binary(title) do
    cleaned =
      @title_watermarks
      |> Enum.reduce(title, &String.replace(&2, &1, " "))
      |> String.replace(~r/[\s\-_|]+/u, " ")
      |> String.trim()

    # What is left has to read like a label, not like punctuation the stripping
    # left behind. "Inglês 5.1" survives; "5.1 [BR]" does not, and its layout is
    # already carried by `channels`.
    if Regex.match?(~r/\p{L}{3,}/u, cleaned), do: cleaned, else: nil
  end

  defp sanitize_title(_title), do: nil

  defp persist(type, id, tracks) do
    case Streamix.Catalog.put_media_track_metadata(type, id, tracks) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("MetadataProbe persist failed: #{inspect(reason)}")
    end
  end

  # When pulled from the DB the keys are strings, but the controller
  # speaks atoms — normalize on read so callers always see the same
  # shape regardless of fresh-vs-cached.
  defp normalize(%{} = m) do
    %{
      audio: normalize_tracks(Map.get(m, "audio", Map.get(m, :audio, []))),
      subtitle: normalize_tracks(Map.get(m, "subtitle", Map.get(m, :subtitle, []))),
      probed_at: Map.get(m, "probed_at", Map.get(m, :probed_at))
    }
  end

  # Rows probed before `sanitize_title/1` existed still hold the watermark, so
  # the same cleaning runs on read. Cheap, and it spares a data migration.
  defp normalize_tracks(tracks) when is_list(tracks), do: Enum.map(tracks, &normalize_track/1)
  defp normalize_tracks(_tracks), do: []

  defp normalize_track(%{"title" => title} = track),
    do: Map.put(track, "title", sanitize_title(title))

  defp normalize_track(%{title: title} = track), do: Map.put(track, :title, sanitize_title(title))
  defp normalize_track(track), do: track
end
