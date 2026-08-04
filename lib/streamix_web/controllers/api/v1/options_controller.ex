defmodule StreamixWeb.Api.V1.OptionsController do
  @moduledoc false

  use StreamixWeb, :controller

  @doc false
  def preflight(conn, _params), do: send_resp(conn, :no_content, "")
end
