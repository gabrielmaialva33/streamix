defmodule StreamixWeb.Api.V1.OptionsController do
  @moduledoc false

  use StreamixWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StreamixWeb.Api.V1.FallbackController

  alias StreamixWeb.Api.V1.Operations

  operation :preflight,
            Operations.build("cors.preflight", "CORS preflight for an API path", nil,
              status: :no_content,
              parameters: [Operations.path(:path)],
              security: []
            )

  @doc false
  def preflight(conn, _params), do: send_resp(conn, :no_content, "")
end
