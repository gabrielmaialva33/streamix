defmodule Streamix.Iptv.Streaming.DirectUrl do
  @moduledoc """
  Safety gate for a final CDN URL handed to a client in direct-client
  playback mode (`providers.direct_client_playback`).

  This is the one place Streamix gives a browser an upstream URL, so the URL
  must carry nothing the account owner did not intend to share:

    * it must be `http` or `https`, with a host and without userinfo;
    * it must not contain the provider's (decrypted) password — raw,
      percent-decoded or percent-encoded. A provider-side redirect that keeps
      the password in the URL is refused, never forwarded;
    * `http` is upgraded to `https` (the measured CDN answers both), and an
      explicit `:80` is dropped, so an `https` page never loads mixed content.

  The URL may still carry the account username and a short-lived CDN token;
  that exposure is the documented, owner-approved cost of the mode. Nothing
  here logs the URL.
  """

  @doc """
  Returns `{:ok, client_url}` or `{:error, :unsafe_url | :credentials_in_url}`.
  """
  @spec prepare(String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :unsafe_url | :credentials_in_url}
  def prepare(url, password) when is_binary(url) do
    with {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.new(url),
         :ok <- refuse_password(url, password) do
      {:ok, uri |> upgrade() |> URI.to_string()}
    else
      {:error, :credentials_in_url} = error -> error
      _ -> {:error, :unsafe_url}
    end
  end

  def prepare(_url, _password), do: {:error, :unsafe_url}

  # `URI.to_string/1` omits the scheme's default port, so `:80` disappears
  # with the upgrade and any other explicit port is kept as is.
  defp upgrade(%URI{scheme: "http", port: port} = uri) when port in [nil, 80],
    do: %{uri | scheme: "https", port: 443}

  defp upgrade(%URI{scheme: "http"} = uri), do: %{uri | scheme: "https"}
  defp upgrade(uri), do: uri

  defp refuse_password(_url, password) when not is_binary(password) or password == "", do: :ok

  defp refuse_password(url, password) do
    forms = Enum.uniq([password, URI.encode_www_form(password), URI.encode(password)])

    if String.contains?(url, forms) or String.contains?(decode(url), password),
      do: {:error, :credentials_in_url},
      else: :ok
  end

  # A malformed escape cannot hide a password from the raw comparison above;
  # the decoded form only adds coverage.
  defp decode(url) do
    URI.decode(url)
  rescue
    ArgumentError -> url
  end
end
