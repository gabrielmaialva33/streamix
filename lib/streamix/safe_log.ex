defmodule Streamix.SafeLog do
  @moduledoc """
  Sanitizes untrusted values before they are written to application logs.

  IPTV URLs may contain provider credentials in path segments, query
  parameters, or URL userinfo. This module keeps redaction consistent across
  streaming code and bounds client-controlled diagnostic values.
  """

  @default_text_limit 256
  @default_url_limit 240

  @credential_path ~r{/(live|movie|series)/[^/?#\s]+/[^/?#\s]+(?=/|$)}i
  @credential_query ~r{([?&](?:username|password|token|api[_-]?key|apikey|auth|authorization)=)[^&#\s]*}i
  @credential_userinfo ~r{(https?://)[^/@\s]+:[^/@\s]+@}i
  @control_characters ~r/[\x00-\x1F\x7F]/u

  @doc """
  Redacts credentials from an HTTP URL and caps the resulting log value.
  """
  @spec redact_url(term(), keyword()) :: String.t()
  def redact_url(value, opts \\ [])

  def redact_url(value, opts) when is_binary(value) do
    max_length = Keyword.get(opts, :max_length, @default_url_limit)

    if String.valid?(value) do
      value
      |> replace_control_characters()
      |> String.replace(@credential_userinfo, "\\1[REDACTED]@")
      |> String.replace(@credential_path, "/\\1/[REDACTED]/[REDACTED]")
      |> String.replace(@credential_query, "\\1[REDACTED]")
      |> truncate(max_length)
    else
      "[invalid-utf8]"
    end
  end

  def redact_url(_value, _opts), do: "[invalid-url]"

  @doc """
  Returns a bounded scalar suitable for structured diagnostic metadata.

  Nested maps and collections are rejected so a public beacon cannot expand a
  single log entry into an arbitrarily large payload.
  """
  @spec scalar(term(), pos_integer()) :: String.t() | number() | boolean() | nil
  def scalar(value, max_length \\ @default_text_limit)

  def scalar(value, max_length) when is_binary(value) do
    if String.valid?(value) do
      value
      |> replace_control_characters()
      |> truncate(max_length)
    else
      "[invalid-utf8]"
    end
  end

  def scalar(value, _max_length) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  def scalar(_value, _max_length), do: "[unsupported]"

  defp replace_control_characters(value) do
    String.replace(value, @control_characters, " ")
  end

  defp truncate(value, max_length) when is_integer(max_length) and max_length > 0 do
    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 1) <> "…"
    else
      value
    end
  end

  defp truncate(_value, _max_length), do: ""
end
