defmodule StreamixWeb.QoeBeaconController do
  @moduledoc """
  Receives one playback-quality sample sent with `navigator.sendBeacon()`.

  The player sends its session summary this way when the page is going away
  (tab closed, reload, navigation), since a LiveView push at that moment is
  lost with the socket. The sample goes through the same bounded, deduplicated
  path as LiveView samples, so a summary that also arrived over the socket is
  stored once.
  """
  use StreamixWeb, :controller

  alias Streamix.Qoe

  def create(conn, params) do
    case conn.assigns[:current_scope] do
      %{user: %{}, library_key: %Streamix.Library.Key{} = library_key} ->
        _result = Qoe.record_client_event(library_key, Map.delete(params, "_csrf_token"))
        send_resp(conn, :no_content, "")

      _anonymous ->
        send_resp(conn, :unauthorized, "")
    end
  end
end
