defmodule StreamixWeb.Telemetry.Handlers do
  @moduledoc """
  Attaches Logger-side handlers on top of the Prometheus reporter so
  failures surface in the server logs even when the dashboard isn't
  open. Prometheus + LiveDashboard still gives the historical view;
  this is the per-incident grep-able trail.

  Attach once at app boot from `StreamixWeb.Telemetry.init/1`.
  """

  require Logger

  @handler_id "streamix-telemetry-handlers"

  @doc """
  Attaches every handler. Idempotent — re-attaches replace previous
  registrations under the same ID.
  """
  def attach do
    detach()

    Enum.each(events(), fn event ->
      :telemetry.attach(handler_id(event), event, &__MODULE__.handle_event/4, nil)
    end)
  end

  @doc """
  Removes every handler this module registered.
  """
  def detach do
    :telemetry.list_handlers([])
    |> Enum.filter(&ours?/1)
    |> Enum.each(&:telemetry.detach(&1.id))
  end

  # One id per event, never `attach_many`. `:telemetry` detaches a handler that
  # raises, and under a shared id that took all fifteen events down together —
  # including the authentication audit trail, which has no Prometheus metric and
  # so has no other sink. Per-event ids keep the blast radius at one event.
  defp handler_id(event), do: @handler_id <> ":" <> Enum.map_join(event, ".", &to_string/1)

  # Handler ids are arbitrary terms; the Prometheus reporter registers tuples.
  defp ours?(%{id: id}) when is_binary(id), do: String.starts_with?(id, @handler_id)
  defp ours?(_handler), do: false

  defp events do
    [
      # Sync pipeline
      [:streamix, :sync, :start],
      [:streamix, :sync, :stop],
      # Oban built-in events
      [:oban, :job, :start],
      [:oban, :job, :stop],
      [:oban, :job, :exception],
      # GIndex scan workers
      [:streamix, :gindex, :scan_root, :stop],
      [:streamix, :gindex, :scan_root, :meta_write_failed],
      # Stream token audit
      [:streamix, :stream_token, :bypass_used],
      [:streamix, :torrent, :session, :state],
      [:streamix, :player, :error],
      # AI recommendations
      [:streamix, :recommendations, :search_failed],
      # Audit / security
      [:streamix, :auth, :api_key, :rejected],
      [:streamix, :auth, :bearer, :rejected],
      [:streamix, :auth, :login, :failed],
      [:streamix, :permission, :denied]
    ]
  end

  # ----- handlers -----

  def handle_event([:streamix, :sync, :start], _measurements, meta, _) do
    Logger.info("[Sync] start provider=#{meta[:provider_id]}")
  end

  def handle_event([:streamix, :sync, :stop], measurements, meta, _) do
    duration_s = native_to_seconds(measurements[:duration])

    Logger.info(
      "[Sync] stop provider=#{meta[:provider_id]} status=#{meta[:status]} " <>
        "duration=#{duration_s}s"
    )
  end

  def handle_event([:oban, :job, :start], _measurements, meta, _) do
    Logger.debug(
      "[Oban] start worker=#{meta[:worker]} queue=#{meta[:queue]} attempt=#{meta[:attempt]}"
    )
  end

  def handle_event([:oban, :job, :stop], measurements, meta, _) do
    duration_ms = native_to_ms(measurements[:duration])

    if meta[:state] in [:failure, :snoozed, :discard, :cancelled] do
      Logger.warning(
        "[Oban] #{meta[:state]} worker=#{meta[:worker]} queue=#{meta[:queue]} " <>
          "attempt=#{meta[:attempt]} duration=#{duration_ms}ms reason=#{inspect(meta[:reason])}"
      )
    end
  end

  def handle_event([:oban, :job, :exception], measurements, meta, _) do
    duration_ms = native_to_ms(measurements[:duration])

    Logger.error(
      "[Oban] EXCEPTION worker=#{meta[:worker]} queue=#{meta[:queue]} " <>
        "attempt=#{meta[:attempt]} duration=#{duration_ms}ms " <>
        "kind=#{meta[:kind]} reason=#{inspect(meta[:reason])}"
    )
  end

  def handle_event([:streamix, :gindex, :scan_root, :stop], measurements, meta, _) do
    duration_ms = measurements[:duration_ms] || 0

    Logger.info(
      "[GIndex ScanRoot] done provider=#{meta[:provider_id]} kind=#{meta[:kind]} " <>
        "duration=#{duration_ms}ms"
    )
  end

  def handle_event([:streamix, :gindex, :scan_root, :meta_write_failed], _, meta, _) do
    Logger.error("[GIndex ScanRoot] meta write failed: #{inspect(meta)}")
  end

  def handle_event([:streamix, :stream_token, :bypass_used], _, _meta, _) do
    # Already logged in resolver.ex — this handler exists so a future
    # dashboard / counter aggregates without changing emission.
    :ok
  end

  def handle_event([:streamix, :torrent, :session, :state], _, meta, _) do
    Streamix.Operations.record_event(:torrent_state, meta[:stage])

    if meta[:stage] in [:degraded, :failed] do
      Logger.warning(
        "[Torrent] state=#{meta[:stage]} attempts=#{meta[:attempts]} " <>
          "failure=#{meta[:failure_code]}"
      )
    end
  end

  def handle_event([:streamix, :player, :error], _, meta, _) do
    Streamix.Operations.record_event(:playback_failure, meta[:stage])

    Logger.warning(
      "[Player] failure stage=#{meta[:stage]} content_type=#{meta[:content_type]} " <>
        "engine=#{meta[:engine]}"
    )
  end

  def handle_event([:streamix, :recommendations, :search_failed], _, meta, _) do
    Logger.warning(
      "[Recommendations] search failed user=#{meta[:user_id]} " <>
        "collection=#{meta[:collection]} reason=#{inspect(meta[:reason])}"
    )
  end

  def handle_event([:streamix, :auth, :api_key, :rejected], _, meta, _) do
    Logger.warning(
      "[Audit] api_key rejected ip=#{meta[:ip]} reason=#{meta[:reason] || "invalid"}"
    )
  end

  def handle_event([:streamix, :auth, :bearer, :rejected], _, meta, _) do
    Logger.warning("[Audit] bearer rejected ip=#{meta[:ip]} reason=#{meta[:reason] || "invalid"}")
  end

  def handle_event([:streamix, :auth, :login, :failed], _, meta, _) do
    Logger.warning(
      "[Audit] login failed account=#{meta[:email_fingerprint]} ip=#{meta[:ip]} reason=#{meta[:reason]}"
    )
  end

  def handle_event([:streamix, :permission, :denied], _, meta, _) do
    Logger.warning(
      "[Audit] permission denied user=#{meta[:user_id]} permission=#{meta[:permission]}"
    )
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  defp native_to_ms(nil), do: 0

  defp native_to_ms(native) do
    System.convert_time_unit(native, :native, :millisecond)
  end

  defp native_to_seconds(nil), do: 0

  defp native_to_seconds(native) do
    System.convert_time_unit(native, :native, :second)
  end
end
