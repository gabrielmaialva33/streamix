defmodule Streamix.Qoe do
  @moduledoc """
  Bounded, privacy-conscious quality-of-experience ingestion.

  Only an explicit metric allowlist is persisted. URLs, titles, credentials and
  arbitrary client payloads are deliberately discarded at this boundary.
  """

  import Ecto.Query

  alias Streamix.Qoe.Event
  alias Streamix.Repo

  @max_batch_size 50
  @max_duration_ms :timer.hours(24)
  @kinds ~w(playback pwa web_vital)
  @events ~w(
    playback_session
    page_vitals
    pwa_install_help_opened
    pwa_install_prompt
    player_error
    install_prompt
    unknown
  )
  @engines ~w(native hls dash shaka mpegts webcodecs avbridge avplayer h265web vlc torrent unknown)
  @content_types ~w(live vod channel movie series episode anime torrent unknown)
  @stream_types ~w(hls mpegts ts mp4 mkv flv dash torrent unknown)
  @display_modes ~w(browser standalone fullscreen minimal-ui unknown)
  @surfaces ~w(home browse watch party favorites history auth settings admin other)
  @outcomes ~w(started playing completed error cancelled restarted accepted dismissed help_opened unknown)
  @enum_aliases %{
    "hls.js" => "hls",
    "hls-js" => "hls",
    "mpegts.js" => "mpegts",
    "mpegts-flv" => "mpegts",
    "av-player" => "avplayer"
  }

  @doc """
  Persists up to 50 samples and returns the number of newly inserted rows.

  The tuple `{user_id, batch_id, sample_index}` is hashed into a unique key, so
  client retries are safe and do not inflate operational metrics.
  """
  def ingest(user_id, batch_id, metrics)
      when (is_integer(user_id) or is_nil(user_id)) and is_binary(batch_id) and
             is_list(metrics) do
    batch_id = normalize_batch_id(batch_id)
    now = DateTime.utc_now(:microsecond)

    entries =
      metrics
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_batch_size)
      |> Enum.with_index()
      |> Enum.map(fn {metric, index} ->
        metric
        |> normalize_metric()
        |> Map.merge(%{
          user_id: user_id,
          batch_id: batch_id,
          sample_index: index,
          dedupe_key: dedupe_key(user_id, batch_id, index),
          inserted_at: now
        })
      end)

    {accepted, inserted} = insert_entries(entries)
    Enum.each(inserted, &emit_metric/1)

    {:ok, %{accepted: accepted, batch_id: batch_id}}
  end

  def ingest(_user_id, _batch_id, _metrics), do: {:error, :invalid_payload}

  @doc "Persists one LiveView/browser sample through the same deduplicated path."
  def record_client_event(user_id, metric) when is_map(metric) do
    batch_id =
      metric
      |> value("batch_id")
      |> bounded_string(128, Ecto.UUID.generate())

    ingest(user_id, batch_id, [metric])
  end

  @doc "Returns a small aggregate used by the admin operational dashboard."
  def summary(opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -86_400, :second))

    Event
    |> where([event], event.inserted_at >= ^since)
    |> select([event], %{
      event_count: count(event.id),
      playback_sessions: fragment("count(*) FILTER (WHERE ? = 'playback')::bigint", event.kind),
      pwa_events: fragment("count(*) FILTER (WHERE ? = 'pwa')::bigint", event.kind),
      web_vitals: fragment("count(*) FILTER (WHERE ? = 'web_vital')::bigint", event.kind),
      avg_ttff_ms:
        fragment(
          "coalesce(round(avg(?) FILTER (WHERE ? = 'playback')), 0)::bigint",
          event.ttff_ms,
          event.kind
        ),
      buffer_count: fragment("coalesce(sum(?), 0)::bigint", event.buffer_count),
      error_count: fragment("coalesce(sum(?), 0)::bigint", event.error_count)
    })
    |> Repo.one()
  end

  @doc "Deletes expired QoE samples and returns the number removed."
  def purge_before(%DateTime{} = cutoff) do
    Event
    |> where([event], event.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  defp insert_entries([]), do: {0, []}

  defp insert_entries(entries) do
    {accepted, inserted} =
      Repo.insert_all(Event, entries,
        on_conflict: :nothing,
        conflict_target: [:dedupe_key],
        returning: [
          :kind,
          :engine,
          :outcome,
          :ttff_ms,
          :buffer_count,
          :buffer_duration_ms
        ]
      )

    {accepted, inserted || []}
  end

  defp normalize_metric(metric) do
    %{
      kind: enum_value(metric, "kind", @kinds, "playback"),
      event: enum_value(metric, ["event", "type"], @events, "unknown"),
      outcome: enum_value(metric, "outcome", @outcomes, "unknown"),
      engine: enum_value(metric, "engine", @engines, "unknown"),
      content_type:
        enum_value(metric, ["content_type", "type", "stream_type"], @content_types, "unknown"),
      stream_type: enum_value(metric, "stream_type", @stream_types, "unknown"),
      surface: enum_value(metric, "surface", @surfaces, "other"),
      display_mode: enum_value(metric, "display_mode", @display_modes, "unknown"),
      ttff_ms: integer_value(metric, ["ttff_ms", "time_to_first_frame_ms"], @max_duration_ms),
      buffer_count: integer_value(metric, ["buffer_count"], 10_000, 0),
      buffer_duration_ms:
        integer_value(
          metric,
          ["buffer_duration_ms", "total_buffer_duration_ms"],
          @max_duration_ms,
          0
        ),
      session_duration_ms: integer_value(metric, ["session_duration_ms"], @max_duration_ms),
      error_count: integer_value(metric, ["error_count"], 10_000, 0),
      fallback_count: integer_value(metric, ["fallback_count"], 10_000, 0),
      muted_mismatch: boolean_value(metric, "muted_mismatch"),
      lcp_ms: integer_value(metric, ["lcp_ms"], @max_duration_ms),
      inp_ms: integer_value(metric, ["inp_ms"], @max_duration_ms),
      cls_milli: integer_value(metric, ["cls_milli"], 1_000_000)
    }
  end

  defp emit_metric(event) do
    :telemetry.execute(
      [:streamix, :qoe, :event],
      %{
        count: 1,
        ttff_ms: event.ttff_ms || 0,
        buffer_count: event.buffer_count || 0,
        buffer_duration_ms: event.buffer_duration_ms || 0
      },
      %{
        kind: event.kind || "unknown",
        engine: event.engine || "unknown",
        outcome: event.outcome || "unknown"
      }
    )
  end

  defp dedupe_key(user_id, batch_id, index) do
    :crypto.hash(:sha256, "#{user_id || "anonymous"}:#{batch_id}:#{index}")
    |> Base.encode16(case: :lower)
  end

  defp enum_value(metric, keys, allowed, fallback) do
    keys
    |> List.wrap()
    |> Enum.find_value(fallback, fn key ->
      normalized =
        metric
        |> value(key)
        |> bounded_string(40, nil)
        |> normalize_enum()

      if normalized in allowed, do: normalized
    end)
  end

  defp normalize_enum(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    Map.get(@enum_aliases, normalized, normalized)
  end

  defp normalize_enum(_value), do: nil

  defp normalize_batch_id(batch_id) do
    batch_id = bounded_string(batch_id, 128, Ecto.UUID.generate())

    case Ecto.UUID.cast(batch_id) do
      {:ok, uuid} -> uuid
      :error -> "sha256:" <> fingerprint(batch_id)
    end
  end

  defp fingerprint(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp bounded_string(value, max_length, _fallback) when is_binary(value) and value != "" do
    String.slice(value, 0, max_length)
  end

  defp bounded_string(_value, _max_length, fallback), do: fallback

  defp integer_value(metric, keys, maximum, fallback \\ nil) do
    value =
      Enum.find_value(keys, fn key ->
        case value(metric, key) do
          number when is_integer(number) -> number
          number when is_float(number) -> round(number)
          _ -> nil
        end
      end)

    if is_integer(value), do: min(max(value, 0), maximum), else: fallback
  end

  defp boolean_value(metric, key), do: value(metric, key) == true
  defp value(metric, key), do: Map.get(metric, key)
end
