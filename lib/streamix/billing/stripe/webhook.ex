defmodule Streamix.Billing.Stripe.Webhook do
  @moduledoc """
  Stripe webhook signature verification.
  """

  @default_tolerance_seconds 300

  def verify(raw_body, signature_header, webhook_secret, opts \\ [])

  def verify(raw_body, signature_header, webhook_secret, opts)
      when is_binary(raw_body) and is_binary(signature_header) and is_binary(webhook_secret) do
    tolerance = Keyword.get(opts, :tolerance_seconds, @default_tolerance_seconds)

    with {:ok, timestamp, signatures} <- parse_signature_header(signature_header),
         :ok <- verify_timestamp(timestamp, tolerance),
         true <- valid_signature?(raw_body, timestamp, signatures, webhook_secret),
         {:ok, event} <- Phoenix.json_library().decode(raw_body) do
      {:ok, event}
    else
      false -> {:error, :invalid_signature}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_raw_body, _signature_header, _webhook_secret, _opts),
    do: {:error, :missing_signature}

  defp parse_signature_header(header) do
    parts =
      header
      |> String.split(",", trim: true)
      |> Enum.map(fn part -> String.split(part, "=", parts: 2) end)

    timestamp =
      Enum.find_value(parts, fn
        ["t", value] -> parse_integer(value)
        _ -> nil
      end)

    signatures =
      Enum.flat_map(parts, fn
        ["v1", value] -> [value]
        _ -> []
      end)

    if timestamp && signatures != [] do
      {:ok, timestamp, signatures}
    else
      {:error, :invalid_signature_header}
    end
  end

  defp verify_timestamp(timestamp, tolerance) do
    if abs(System.system_time(:second) - timestamp) <= tolerance do
      :ok
    else
      {:error, :stale_signature}
    end
  end

  defp valid_signature?(raw_body, timestamp, signatures, webhook_secret) do
    signed_payload = "#{timestamp}.#{raw_body}"

    expected =
      :hmac
      |> :crypto.mac(:sha256, webhook_secret, signed_payload)
      |> Base.encode16(case: :lower)

    Enum.any?(signatures, &Plug.Crypto.secure_compare(expected, &1))
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
