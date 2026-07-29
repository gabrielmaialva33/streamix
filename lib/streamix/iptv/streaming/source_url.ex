defmodule Streamix.Iptv.Streaming.SourceUrl do
  @moduledoc """
  Builds and verifies signed URLs that point straight at the
  `source.mahina.cloud` reverse proxy, so the browser can fetch the
  upstream IPTV stream **without** going through the Phoenix
  `/api/stream/proxy` 302 redirect.

  ## Why

  The redirect bounce costs one full RTT (browser → CF → Tunnel →
  Phoenix → 302 → CF → source). For a US-East ↔ Brazil round-trip,
  that's 50-80ms of pure network time the user pays *before* a single
  byte of video reaches the player. Once the redirect chain has been
  resolved by `Streamix.Iptv.Streaming.RedirectResolver`, we know the
  final URL. Signing it with HMAC + short expiry lets the browser hit
  the source directly while keeping access control.

  ## Wire format

      https://source.mahina.cloud/proxy?url=<encoded>&exp=<unix>&sig=<base64url>

  - `url` — the upstream URL the source should `proxy_pass` to.
  - `exp` — Unix timestamp (seconds) past which the URL is rejected.
  - `sig` — `base64url(md5_binary("<exp>:<url> <secret>"))`, no padding.

  The token format mirrors what `ngx_http_secure_link_module` validates
  natively, so the verification on the source side is just two nginx
  directives — no Lua, no external module:

      secure_link $arg_sig,$arg_exp;
      secure_link_md5 "$arg_exp:$arg_url SECRET";

  The shared secret is configured via `SOURCE_PROXY_SHARED_SECRET` and
  must match the secret embedded in those nginx directives. When unset
  (dev / tests without the proxy), `build/2` returns `{:error, :no_secret}`
  and callers fall back to the Phoenix-mediated 302 path.
  """

  @default_ttl_seconds 300

  @spec build(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :no_secret | :no_proxy_base}
  def build(upstream_url, opts \\ []) when is_binary(upstream_url) do
    with {:ok, secret} <- fetch_secret(),
         {:ok, base} <- fetch_proxy_base() do
      ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
      exp = Keyword.get(opts, :exp_at, System.system_time(:second) + ttl)
      sig = sign(secret, exp, upstream_url)

      qs =
        URI.encode_query(%{
          "url" => upstream_url,
          "exp" => Integer.to_string(exp),
          "sig" => sig
        })

      {:ok, "#{String.trim_trailing(base, "/")}/proxy?#{qs}"}
    end
  end

  @doc """
  Verifies a query map (used in dev/tests; nginx is the production
  verifier).
  """
  @spec verify(map()) :: :ok | {:error, :missing | :expired | :bad_sig | :no_secret}
  def verify(%{"url" => url, "exp" => exp, "sig" => sig})
      when is_binary(url) and is_binary(exp) and is_binary(sig) do
    with {:ok, secret} <- fetch_secret(),
         {:ok, exp_int} <- parse_exp(exp),
         :fresh <- freshness(exp_int),
         expected = sign(secret, exp_int, url),
         true <- Plug.Crypto.secure_compare(expected, sig) do
      :ok
    else
      :expired -> {:error, :expired}
      false -> {:error, :bad_sig}
      {:error, _} = err -> err
    end
  end

  def verify(_), do: {:error, :missing}

  defp parse_exp(exp) do
    case Integer.parse(exp) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :missing}
    end
  end

  defp freshness(exp_int) do
    if exp_int > System.system_time(:second), do: :fresh, else: :expired
  end

  # Matches nginx `secure_link_md5 "$arg_exp:$arg_url SECRET"`.
  defp sign(secret, exp, url) do
    payload = "#{exp}:#{url} #{secret}"

    :crypto.hash(:md5, payload)
    |> Base.url_encode64(padding: false)
  end

  defp fetch_secret do
    case Application.get_env(:streamix, :source_proxy_shared_secret) do
      nil -> {:error, :no_secret}
      "" -> {:error, :no_secret}
      secret when is_binary(secret) -> {:ok, secret}
    end
  end

  defp fetch_proxy_base do
    case Application.get_env(:streamix, :stream_proxy_url) do
      nil -> {:error, :no_proxy_base}
      "" -> {:error, :no_proxy_base}
      base when is_binary(base) -> {:ok, base}
    end
  end
end
