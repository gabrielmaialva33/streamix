defmodule StreamixWeb.Plugs.PreserveMethod do
  @moduledoc """
  Preserves the original HTTP method before Plug.Head converts HEAD to GET.
  This allows controllers to distinguish HEAD requests from GET requests.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, :original_method, conn.method)
  end
end
