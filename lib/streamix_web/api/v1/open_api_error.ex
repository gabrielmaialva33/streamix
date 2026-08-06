defmodule StreamixWeb.Api.V1.OpenApiError do
  @moduledoc false

  @behaviour Plug

  alias StreamixWeb.Api.V1.Response

  @impl Plug
  def init(errors), do: List.wrap(errors)

  @impl Plug
  def call(conn, errors) do
    {code, message} = errors |> List.first() |> parameter_name() |> error_response()
    Response.error(conn, :bad_request, code, message)
  end

  defp error_response(name) when name in ["provider_id", :provider_id],
    do: {"invalid_provider_id", "Invalid provider id"}

  defp error_response(name) when name in ["provider_type", :provider_type],
    do: {"invalid_provider_type", "Provider type must be xtream, gindex, or torrent"}

  defp error_response(name)
       when (is_atom(name) and not is_nil(name)) or (is_binary(name) and name != ""),
       do: {"invalid_parameter", "Invalid value for parameter #{name}"}

  defp error_response(_name), do: {"invalid_request", "Invalid request parameters"}

  defp parameter_name(%{name: name})
       when (is_atom(name) and not is_nil(name)) or (is_binary(name) and name != ""),
       do: name

  defp parameter_name(%{path: path}) when is_list(path), do: List.last(path)
  defp parameter_name(_error), do: nil
end
