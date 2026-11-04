defmodule StreamixWeb.ErrorJSON do
  @moduledoc "Renders endpoint failures, preserving the v1 envelope under /api."

  alias StreamixWeb.Api.V1.Response

  def render(template, %{conn: %{path_info: ["api" | _]}}) do
    message = Phoenix.Controller.status_message_from_template(template)
    code = message |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    Response.error_body(code, message)
  end

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
