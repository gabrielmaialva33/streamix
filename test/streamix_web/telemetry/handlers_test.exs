defmodule StreamixWeb.Telemetry.HandlersTest do
  @moduledoc """
  These handlers are the only sink for the authentication audit trail: there is
  no Prometheus metric for `auth.login.failed`, `api_key.rejected` or
  `bearer.rejected`, so if the Logger side goes quiet those events leave no
  record anywhere.

  `:telemetry` detaches a handler that raises. Because every event was attached
  under a single `attach_many` id, one raising handler took all fifteen events
  down with it — and `player_error` carried client-supplied values straight
  into a log interpolation, so any signed-in viewer could trigger it from a
  websocket frame. What these tests pin is the blast radius.
  """
  use ExUnit.Case, async: false

  alias StreamixWeb.Telemetry.Handlers

  @auth_event [:streamix, :auth, :login, :failed]
  @player_error [:streamix, :player, :error]

  setup do
    Handlers.attach()
    on_exit(&Handlers.attach/0)
    :ok
  end

  # Handler ids are arbitrary terms — the Prometheus reporter registers tuples —
  # so match on binaries only. (Interpolating one of those into a string is the
  # very fault these tests are about; this helper managed to reproduce it.)
  defp ours?(%{id: id}) when is_binary(id), do: String.starts_with?(id, "streamix-telemetry")
  defp ours?(_handler), do: false

  defp our_handlers, do: Enum.filter(:telemetry.list_handlers([]), &ours?/1)

  defp detach_all, do: Enum.each(our_handlers(), &:telemetry.detach(&1.id))

  defp attached_events, do: MapSet.new(our_handlers(), & &1.event_name)

  test "a raising handler cannot take the authentication audit trail with it" do
    assert @auth_event in attached_events()

    # A map has no String.Chars implementation, so interpolating it raises
    # inside the handler. This is what a crafted `player_error` payload does.
    :telemetry.execute(@player_error, %{system_time: 0}, %{
      stage: %{"nested" => "map"},
      content_type: "movie",
      engine: "native"
    })

    assert @auth_event in attached_events(),
           "one bad player_error detached the auth audit handlers — a signed-in " <>
             "viewer can silence login-failure logging from a websocket frame"
  end

  test "auth events still reach the log after a player_error storm" do
    for _ <- 1..5 do
      :telemetry.execute(@player_error, %{system_time: 0}, %{
        stage: %{"a" => 1},
        content_type: ["list", "value"],
        engine: %{"b" => 2}
      })
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :telemetry.execute(@auth_event, %{count: 1}, %{
          email_fingerprint: "probe-fingerprint",
          ip: "203.0.113.9",
          reason: :bad_password
        })
      end)

    assert log =~ "probe-fingerprint",
           "the audit sink went silent after malformed player errors"
  end

  test "every declared event is attached" do
    attached = attached_events()

    for event <- [
          @auth_event,
          [:streamix, :auth, :api_key, :rejected],
          [:streamix, :auth, :bearer, :rejected],
          [:streamix, :permission, :denied],
          [:streamix, :stream_token, :bypass_used]
        ] do
      assert event in attached, "#{inspect(event)} is not attached"
    end
  end
end
