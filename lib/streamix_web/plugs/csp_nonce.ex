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
    extra_script_hosts =
      :streamix
      |> Application.get_env(:csp_extra_script_hosts, [])
      |> Enum.join(" ")

    [
      # Default: only allow same origin
      "default-src 'self'",

      # Scripts: nonce-based (no strict-dynamic — conflicts with Cloudflare injected scripts)
      # unsafe-eval needed for LiveView morphdom diffing
      # Hash: Cloudflare Speed Brain inline speculation rules
      # blob:: AVPlayer loads its WASM/decoder workers as <script src="blob:...">
      # at runtime; without this we get "Failed to load because no supported source
      # was found" on movie playback when the engine falls back to AVPlayer.
      # Extra hosts come from :csp_extra_script_hosts in config so prod can
      # add CDNs without touching this file (and the env-driven path means
      # runtime.exs picks up CSP_EXTRA_SCRIPT_HOSTS without a redeploy).
      "script-src 'self' 'nonce-#{nonce}' 'unsafe-eval' blob: 'sha256-iIs9B1z3EnV2hTwzvh58h4Re7d6yNBJdIX4csEJo7c0=' https://static.cloudflareinsights.com https://ajax.cloudflare.com https://cdnjs.cloudflare.com https://www.youtube.com https://s.ytimg.com #{extra_script_hosts}"
      |> String.trim_trailing(),

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
      "object-src 'none'"

      # NOTE: upgrade-insecure-requests removed — IPTV providers serve
      # HTTP-only streams on bare IPs, upgrading breaks playback
    ]
    |> Enum.join("; ")
  end
end
