defmodule StreamixWeb.StreamErrors do
  @moduledoc """
  Compatibility wrapper for the playback error contract.
  """

  alias Streamix.Playback

  @type code :: Playback.stream_error_code()

  defdelegate halt(conn, code, opts \\ []), to: Playback, as: :halt_stream_error
  defdelegate code_from_reason(reason), to: Playback, as: :stream_error_code_from_reason
end
