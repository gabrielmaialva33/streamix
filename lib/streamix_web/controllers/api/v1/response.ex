defmodule StreamixWeb.Api.V1.Response do
  @moduledoc """
  Stable JSON error responses shared by the v1 API.

  Raw internal failure reasons stay in server-side telemetry/log metadata and
  are never serialized to mobile, TV, or browser clients.
  """

  import Plug.Conn, only: [put_status: 2]

  require Logger

  @spec error(Plug.Conn.t(), Plug.Conn.status(), String.t(), String.t(), keyword() | map()) ::
          Plug.Conn.t()
  def error(conn, status, code, message, extra \\ []) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(error_body(code, message, extra))
  end

  @doc "Builds the same envelope for controller and endpoint errors."
  @spec error_body(String.t(), String.t(), keyword() | map()) :: map()
  def error_body(code, message, extra \\ []) do
    %{error: extra |> Map.new() |> Map.merge(%{code: code, message: message})}
  end

  @spec internal_error(
          Plug.Conn.t(),
          Plug.Conn.status(),
          String.t(),
          String.t(),
          term()
        ) :: Plug.Conn.t()
  def internal_error(conn, status, code, message, reason) do
    Logger.error("API operation failed",
      api_error_code: code,
      reason_kind: reason_kind(reason)
    )

    error(conn, status, code, message)
  end

  @doc "Returns a stable, human-readable message for an Ecto changeset."
  @spec changeset_message(Ecto.Changeset.t()) :: String.t()
  def changeset_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate_changeset_error/1)
    |> Enum.map_join("; ", fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
  end

  # Only placeholders the message names are filled in. Validation options also
  # carry values that are not text (unsafe_validate_unique adds
  # `fields: [:email]`), and stringifying every option crashed a duplicate
  # email registration into a 500.
  defp interpolate_changeset_error({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn placeholder, key ->
      case Enum.find(opts, fn {name, _value} -> Atom.to_string(name) == key end) do
        {_name, value} -> interpolation_value(value)
        nil -> placeholder
      end
    end)
  end

  defp interpolation_value(value) when is_binary(value), do: value

  defp interpolation_value(value) when is_number(value) or is_atom(value),
    do: to_string(value)

  defp interpolation_value(value), do: inspect(value)

  defp reason_kind(reason) when is_atom(reason), do: reason
  defp reason_kind({tag, _value}) when is_atom(tag), do: tag
  defp reason_kind({tag, _value, _metadata}) when is_atom(tag), do: tag
  defp reason_kind(%module{}), do: module
  defp reason_kind(reason) when is_binary(reason), do: :binary
  defp reason_kind(reason) when is_map(reason), do: :map
  defp reason_kind(reason) when is_list(reason), do: :list
  defp reason_kind(reason) when is_tuple(reason), do: :tuple
  defp reason_kind(_reason), do: :other
end
