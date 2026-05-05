defmodule StreamixWeb.StreamErrors do
  @moduledoc """
  Compatibility wrapper for `Streamix.Iptv.Streaming.StreamErrors`.
  """

  alias Streamix.Iptv.Streaming.StreamErrors

  @type code :: StreamErrors.code()

  defdelegate halt(conn, code, opts \\ []), to: StreamErrors
  defdelegate code_from_reason(reason), to: StreamErrors
end
