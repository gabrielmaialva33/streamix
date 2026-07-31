defmodule Streamix.Iptv.ProviderCapabilities do
  @moduledoc """
  Safe, normalized view of the Xtream account capabilities.

  Xtream installations return most values as strings and differ slightly in
  casing and missing fields. This module is deliberately pure: it converts the
  authenticated `player_api.php` response into data that can be exposed by
  health endpoints without retaining credentials or the raw payload.
  """

  @expiry_warning_seconds 72 * 60 * 60

  @enforce_keys [:authenticated?, :active?]
  defstruct authenticated?: false,
            active?: false,
            status: nil,
            expires_at: nil,
            max_connections: 1,
            active_connections: 0,
            allowed_output_formats: [],
            server_protocol: nil

  @type t :: %__MODULE__{
          authenticated?: boolean(),
          active?: boolean(),
          status: String.t() | nil,
          expires_at: DateTime.t() | nil,
          max_connections: pos_integer(),
          active_connections: non_neg_integer(),
          allowed_output_formats: [String.t()],
          server_protocol: String.t() | nil
        }

  @doc "Parses an authenticated Xtream account response."
  @spec from_account_info(term()) :: {:ok, t()} | {:error, :invalid_account_info}
  def from_account_info(%{"user_info" => user_info} = payload) when is_map(user_info) do
    server_info = Map.get(payload, "server_info", %{})
    authenticated? = truthy?(Map.get(user_info, "auth"))
    status = normalized_string(Map.get(user_info, "status"))
    expires_at = parse_epoch(Map.get(user_info, "exp_date"))

    capabilities = %__MODULE__{
      authenticated?: authenticated?,
      active?: authenticated? and active_status?(status) and not expired?(expires_at),
      status: status,
      expires_at: expires_at,
      max_connections: positive_integer(Map.get(user_info, "max_connections"), 1),
      active_connections: non_negative_integer(Map.get(user_info, "active_cons"), 0),
      allowed_output_formats: output_formats(Map.get(user_info, "allowed_output_formats")),
      server_protocol: normalized_string(Map.get(server_info, "server_protocol"))
    }

    {:ok, capabilities}
  end

  def from_account_info(_), do: {:error, :invalid_account_info}

  @doc "Classifies account health independently from transport health."
  @spec status(t(), DateTime.t()) :: :healthy | :degraded | :unhealthy
  def status(%__MODULE__{} = capabilities, now \\ DateTime.utc_now()) do
    cond do
      not capabilities.authenticated? -> :unhealthy
      not capabilities.active? -> :unhealthy
      expired_at?(capabilities.expires_at, now) -> :unhealthy
      expiring_soon?(capabilities.expires_at, now) -> :degraded
      capabilities.active_connections >= capabilities.max_connections -> :degraded
      true -> :healthy
    end
  end

  @doc "Returns the client-safe capability fields used by health reports."
  @spec public(t()) :: map()
  def public(%__MODULE__{} = capabilities) do
    %{
      authenticated: capabilities.authenticated?,
      active: capabilities.active?,
      status: capabilities.status,
      expires_at: capabilities.expires_at,
      max_connections: capabilities.max_connections,
      active_connections: capabilities.active_connections,
      allowed_output_formats: capabilities.allowed_output_formats,
      server_protocol: capabilities.server_protocol
    }
  end

  defp truthy?(value), do: value in [true, 1, "1", "true", "TRUE"]

  defp active_status?(nil), do: true

  defp active_status?(status) do
    String.downcase(status) in ["active", "enabled"]
  end

  defp expired?(nil), do: false
  defp expired?(expires_at), do: DateTime.compare(expires_at, DateTime.utc_now()) == :lt

  defp expired_at?(nil, _now), do: false
  defp expired_at?(expires_at, now), do: DateTime.compare(expires_at, now) == :lt

  defp expiring_soon?(nil, _now), do: false

  defp expiring_soon?(expires_at, now) do
    DateTime.diff(expires_at, now, :second) <= @expiry_warning_seconds
  end

  defp output_formats(formats) when is_list(formats) do
    formats
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp output_formats(format) when is_binary(format), do: output_formats([format])
  defp output_formats(_), do: []

  defp positive_integer(value, default) do
    case parse_integer(value) do
      parsed when is_integer(parsed) and parsed > 0 -> parsed
      _ -> default
    end
  end

  defp non_negative_integer(value, default) do
    case parse_integer(value) do
      parsed when is_integer(parsed) and parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp parse_epoch(value) do
    case parse_integer(value) do
      epoch when is_integer(epoch) and epoch > 0 ->
        case DateTime.from_unix(epoch) do
          {:ok, datetime} -> datetime
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_string(_), do: nil
end
