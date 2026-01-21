defmodule StreamixWeb.Plugs.CSPNonce do
  @moduledoc """
  Generates a cryptographic nonce for Content Security Policy.

  The nonce is stored in conn.assigns[:csp_nonce] and should be used
  in script tags that need to execute inline JavaScript.

  Usage in templates:
    <script nonce={@csp_nonce}>
      // inline script here
    </script>

  The CSP header will automatically include this nonce.
  """

  import Plug.Conn

  @nonce_length 16

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = generate_nonce()

    conn
    |> assign(:csp_nonce, nonce)
    |> register_before_send(&inject_csp_header(&1, nonce))
  end

  defp generate_nonce do
    @nonce_length
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp inject_csp_header(conn, nonce) do
    csp = build_csp(nonce)

    # Replace or add CSP header
    conn
    |> delete_resp_header("content-security-policy")
    |> put_resp_header("content-security-policy", csp)
  end

  defp build_csp(nonce) do
    [
      # Default: only allow same origin
      "default-src 'self'",

      # Scripts: nonce-based + strict-dynamic for loaded scripts
      # unsafe-eval still needed for LiveView morphdom diffing
      "script-src 'self' 'nonce-#{nonce}' 'strict-dynamic' 'unsafe-eval' https://static.cloudflareinsights.com",

      # Styles: unsafe-inline still needed for Tailwind dynamic classes and LiveView
      "style-src 'self' 'unsafe-inline'",

      # Images: allow data URIs, HTTPS, and blobs for thumbnails
      "img-src 'self' data: https: blob:",

      # Media: allow HTTPS streams and blobs for HLS
      "media-src 'self' https: blob:",

      # Fonts: self and data URIs
      "font-src 'self' data:",

      # Connect: WebSocket for LiveView, HTTPS for APIs
      "connect-src 'self' wss: https: blob:",

      # Workers: Service Worker and blob workers for HLS
      "worker-src 'self' blob:",

      # Frames: allow HTTPS embeds
      "frame-src 'self' https:",

      # Base URI: prevent base tag hijacking
      "base-uri 'self'",

      # Form actions: only allow same origin
      "form-action 'self'",

      # Frame ancestors: prevent clickjacking
      "frame-ancestors 'self'",

      # Object: disable plugins
      "object-src 'none'",

      # Upgrade insecure requests in production
      "upgrade-insecure-requests"
    ]
    |> Enum.join("; ")
  end
end
