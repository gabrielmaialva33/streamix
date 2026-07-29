defmodule StreamixWeb.StreamErrors do
  @moduledoc """
  Compatibility wrapper for `Streamix.Iptv.Streaming.StreamErrors`.
  """

  alias Streamix.Iptv

  @type code :: Iptv.stream_error_code()

  defdelegate halt(conn, code, opts \\ []), to: Iptv, as: :halt_stream_error
  defdelegate code_from_reason(reason), to: Iptv, as: :stream_error_code_from_reason
end
