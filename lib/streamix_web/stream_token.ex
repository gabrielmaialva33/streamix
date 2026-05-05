defmodule StreamixWeb.StreamToken do
  @moduledoc """
  Generates and verifies signed tokens for streaming content.

  This prevents exposing provider credentials in API responses.
  Instead of returning URLs with embedded username/password, we return
  a signed token that can be exchanged for the actual stream URL server-side.

  Tokens are bound to a specific user_id, ensuring a leaked token cannot be
  used by a different user. The embedded user_id is verified against provider
  ownership at consumption time.
  """

  alias Streamix.Access
  alias Streamix.Accounts
  alias Streamix.Iptv
  alias StreamixWeb.UrlValidator

  # Token expires in 2 hours (reduced from 24h for security)
  @token_max_age 7_200

  @doc """
  Generates a signed token for accessing a movie stream.
  The `user_id` is embedded in the token and verified on consumption.
  Pass `nil` for public/global provider content (catalog API).

  ## Options

    * `:bypass_subscription` — embed an integration-authorized flag inside
      the signed token. Callers that already proved authorization (e.g.
      requests with a valid `X-API-Key` hitting the catalog API) should
      set this so the stream proxy skips the subscription check, even
      when the URL is later fetched by an intermediate proxy that strips
      auth headers. The token signature prevents forgery.
  """
  def sign_movie(movie_id, user_id, opts \\ []) when is_integer(movie_id) do
    sign_content("movie", movie_id, user_id, opts)
  end

  @doc """
  Generates a signed token for accessing an episode stream.
  See `sign_movie/3` for options.
  """
  def sign_episode(episode_id, user_id, opts \\ []) when is_integer(episode_id) do
    sign_content("episode", episode_id, user_id, opts)
  end

  @doc """
  Generates a signed token for accessing a channel stream.
  See `sign_movie/3` for options.
  """
  def sign_channel(channel_id, user_id, opts \\ []) when is_integer(channel_id) do
    sign_content("channel", channel_id, user_id, opts)
  end

  @doc """
  Generates a signed token for proxying an external URL.
  Used for GIndex and other external sources that need CORS headers.
  The `user_id` is embedded in the token and verified on consumption.
  Pass `provider_id` so provider visibility/ownership can be revalidated
  when the token is consumed.
  """
  def sign_url(url, user_id, opts \\ []) when is_binary(url) do
    case UrlValidator.validate_url(url) do
      :ok ->
        premium_required = Keyword.get(opts, :premium_required, false)
        provider_id = Keyword.get(opts, :provider_id)
        bypass = Keyword.get(opts, :bypass_subscription, false)

        data = %{
          type: "url",
          url: url,
          user_id: user_id,
          provider_id: provider_id,
          premium_required: premium_required,
          bypass: bypass
        }

        Phoenix.Token.sign(StreamixWeb.Endpoint, "stream", data)

      {:error, :unsafe_url} ->
        {:error, :unsafe_url}
    end
  end

  @doc """
  Verifies a token and returns the actual stream URL if valid.
  Returns `{:ok, url, content_type, meta}` or `{:error, reason}`.

  `content_type` is "channel", "movie", "episode", or "url".
  `meta` is a map with type-specific fields; always contains `:content_id`
  (the DB id of the resolved channel/movie/episode, or `nil` for raw URL
  tokens) so the stream proxy can act on terminal upstream errors (e.g.
  mark a live channel dead when the upstream returns 404).

  The embedded user_id is checked against provider ownership:
  - If user_id is present, the content's provider must belong to that user
    or be a public/global provider.
  - If user_id is nil (public catalog token), the provider must be public/global.

  ## Options

    * `:bypass_subscription` — when `true`, skips the subscription / premium
      access check for global-provider content. The caller is responsible
      for establishing authorization out-of-band (e.g. by validating a
      privileged `X-API-Key` on the request before calling verify). Token
      signature + provider visibility are still verified. Default: `false`.
  """
  def verify_and_get_url(token, opts \\ []) do
    external_bypass = Keyword.get(opts, :bypass_subscription, false)

    case verify_token(token) do
      {:ok, claims} -> dispatch_claims(claims, external_bypass)
      {:error, :expired} -> {:error, :token_expired}
      {:error, _reason} -> {:error, :invalid_token}
    end
  end

  defp dispatch_claims(
         %{
           type: "url",
           url: url,
           user_id: user_id,
           provider_id: provider_id,
           premium_required: premium_required
         } = claims,
         external_bypass
       ) do
    bypass = effective_bypass(claims, external_bypass)

    with {:ok, url, "url"} <-
           handle_url_token(url, user_id, provider_id, premium_required, bypass) do
      {:ok, url, "url", %{content_id: nil}}
    end
  end

  defp dispatch_claims(%{type: "url"}, _external_bypass), do: {:error, :invalid_token}

  defp dispatch_claims(%{type: type, id: id, user_id: user_id} = claims, external_bypass) do
    bypass = effective_bypass(claims, external_bypass)

    with {:ok, url, ^type} <- handle_content_token(type, id, user_id, bypass) do
      {:ok, url, type, %{content_id: id}}
    end
  end

  defp dispatch_claims(_claims, _external_bypass), do: {:error, :invalid_token}

  defp effective_bypass(claims, external_bypass) do
    external_bypass or Map.get(claims, :bypass, false)
  end

  # Private functions

  defp sign_content(type, id, user_id, opts) do
    data = %{
      type: type,
      id: id,
      user_id: user_id,
      bypass: Keyword.get(opts, :bypass_subscription, false)
    }

    Phoenix.Token.sign(StreamixWeb.Endpoint, "stream", data)
  end

  defp verify_token(token) do
    Phoenix.Token.verify(StreamixWeb.Endpoint, "stream", token, max_age: @token_max_age)
  end

  defp validate_direct_url(url) do
    case UrlValidator.validate_url(url) do
      :ok -> {:ok, url, "url"}
      {:error, :unsafe_url} -> {:error, :unsafe_url}
    end
  end

  defp handle_url_token(url, user_id, provider_id, premium_required, bypass_subscription) do
    case Iptv.get_provider(provider_id) do
      nil ->
        {:error, :invalid_token}

      provider ->
        if premium_required and not Access.global_content?(provider) do
          {:error, :invalid_token}
        else
          authorize_url_token(url, user_id, provider, bypass_subscription)
        end
    end
  end

  defp authorize_url_token(url, user_id, provider, bypass_subscription) do
    cond do
      Access.global_content?(provider) ->
        user_has_global_access?(user_id, provider, url, bypass_subscription)

      provider.visibility in [:public, "public"] ->
        validate_direct_url(url)

      provider.visibility in [:private, "private"] ->
        authorized_private_url_token?(url, user_id, provider)

      true ->
        {:error, :invalid_token}
    end
  end

  # Bypass path: X-API-Key-backed integration. Subscription/user checks are
  # skipped — the caller is trusted to have already authorized the request.
  defp user_has_global_access?(_user_id, _provider, url, true), do: validate_direct_url(url)

  defp user_has_global_access?(nil, _provider, _url, _bypass),
    do: {:error, :subscription_required}

  defp user_has_global_access?(user_id, provider, url, _bypass) do
    case Accounts.get_user(user_id) do
      nil ->
        {:error, :subscription_required}

      user ->
        if Access.can_play_global_content?(user, provider) do
          :ok
        else
          {:error, :subscription_required}
        end
        |> case do
          :ok -> validate_direct_url(url)
          error -> error
        end
    end
  end

  defp authorized_private_url_token?(_url, nil, _provider), do: {:error, :unauthorized}

  defp authorized_private_url_token?(url, user_id, %{user_id: provider_user_id})
       when is_integer(provider_user_id) do
    case Accounts.get_user(user_id) do
      nil ->
        {:error, :invalid_token}

      _user ->
        if user_id == provider_user_id do
          validate_direct_url(url)
        else
          {:error, :unauthorized}
        end
    end
  end

  defp authorized_private_url_token?(_url, _user_id, _provider), do: {:error, :invalid_token}

  defp handle_content_token(type, id, user_id, bypass_subscription) do
    case get_stream_url(type, id, user_id, bypass_subscription) do
      {:ok, url} -> {:ok, url, type}
      error -> error
    end
  end

  @doc """
  Returns the raw upstream URL that the given content would resolve to
  if its token were verified.

  Used by `PlayerLive.mount/3` to prewarm the redirect-chain resolver
  without round-tripping through the signed-token exchange. The same
  authorization checks as `verify_and_get_url/2` are applied — a user
  who is not allowed to play the content gets `{:error, …}` here too.
  """
  def upstream_url(type, id, user_id, opts \\ [])
      when type in ["movie", "episode", "channel"] and is_integer(id) do
    bypass = Keyword.get(opts, :bypass_subscription, false)
    get_stream_url(type, id, user_id, bypass)
  end

  defp get_stream_url("movie", id, user_id, bypass) do
    case Iptv.get_movie_for_stream(id) do
      nil ->
        {:error, :not_found}

      movie ->
        provider = movie.provider

        build_content_url(
          provider,
          user_id,
          movie,
          "movie",
          movie.stream_id,
          movie.container_extension,
          bypass
        )
    end
  end

  defp get_stream_url("episode", id, user_id, bypass) do
    case Iptv.get_episode_for_stream(id) do
      nil ->
        {:error, :not_found}

      episode ->
        provider = episode.season.series.provider

        build_content_url(
          provider,
          user_id,
          episode,
          "series",
          episode.episode_id,
          episode.container_extension,
          bypass
        )
    end
  end

  defp get_stream_url("channel", id, user_id, bypass) do
    case Iptv.get_live_channel_for_stream(id) do
      nil ->
        {:error, :not_found}

      channel ->
        provider = channel.provider

        build_content_url(provider, user_id, channel, "live", channel.stream_id, "ts", bypass)
    end
  end

  defp build_content_url(provider, user_id, content, content_path, stream_id, extension, bypass) do
    cond do
      Access.global_content?(provider) ->
        build_global_content_url(
          provider,
          user_id,
          content,
          content_path,
          stream_id,
          extension,
          bypass
        )

      authorized_for_provider?(user_id, provider) ->
        build_provider_content_url(provider, content_path, stream_id, extension)

      true ->
        {:error, :unauthorized}
    end
  end

  # Bypass path — integration-authorized (API key) request, skip user lookup.
  defp build_global_content_url(
         provider,
         _user_id,
         _content,
         content_path,
         stream_id,
         extension,
         true
       ) do
    build_provider_content_url(provider, content_path, stream_id, extension)
  end

  defp build_global_content_url(
         _provider,
         nil,
         _content,
         _content_path,
         _stream_id,
         _extension,
         _bypass
       ) do
    {:error, :subscription_required}
  end

  defp build_global_content_url(
         provider,
         user_id,
         content,
         content_path,
         stream_id,
         extension,
         _bypass
       ) do
    case Accounts.get_user(user_id) do
      nil ->
        {:error, :subscription_required}

      user ->
        if Access.can_play_global_content?(user, content) do
          build_provider_content_url(provider, content_path, stream_id, extension)
        else
          {:error, :subscription_required}
        end
    end
  end

  defp build_provider_content_url(provider, "movie", stream_id, extension) do
    build_signed_or_creds_url(provider, "movie", stream_id, extension || "mp4")
  end

  defp build_provider_content_url(provider, "series", stream_id, extension) do
    build_signed_or_creds_url(provider, "series", stream_id, extension || "mp4")
  end

  defp build_provider_content_url(provider, "live", stream_id, _extension) do
    # Use .ts for direct MPEG-TS streaming (not .m3u8 which is a playlist)
    # to avoid mixed content issues with HLS segment URLs.
    build_signed_or_creds_url(provider, "live", stream_id, "ts")
  end

  defp build_signed_or_creds_url(provider, type, stream_id, ext) do
    case tuliprox_signed_url(type, stream_id, ext) do
      {:ok, url} ->
        {:ok, url}

      :no_signing ->
        # Legacy path: dump the upstream credentials in the URL so the
        # browser → source.mahina.cloud nginx → upstream chain still
        # works for non-Tuliprox providers (GIndex, etc).
        url =
          "#{public_base(provider)}/#{type}/#{provider.username}/#{provider.password}/#{stream_id}.#{ext}"

        {:ok, url}
    end
  end

  # When the operator wires up Tuliprox + the signed-URL nginx vhost, we
  # build a short-lived HMAC URL that exposes neither provider creds nor
  # the Tuliprox internal user/pass. The nginx Lua block in front of
  # Tuliprox validates the signature, rewrites with the server-side
  # credentials and proxies. If `:tuliprox_sign_secret` isn't set we fall
  # through to the legacy creds-in-URL path.
  defp tuliprox_signed_url(type, stream_id, ext) do
    secret = Application.get_env(:streamix, :tuliprox_sign_secret, "")
    base = Application.get_env(:streamix, :tuliprox_public_url, "")

    cond do
      secret == "" or base == "" ->
        :no_signing

      true ->
        # 5 minutes is enough for the player to follow the 302 + start
        # pulling bytes. nginx rejects expired tokens with 410 Gone; the
        # underlying TCP connection keeps streaming once accepted, so a
        # 4-hour movie playback isn't capped by the URL TTL.
        exp = System.system_time(:second) + 300
        payload = "#{exp}:#{type}:#{stream_id} #{secret}"

        sig =
          payload
          |> :erlang.md5()
          |> Base.url_encode64(padding: false)

        {:ok, "#{base}/s/#{type}/#{stream_id}.#{ext}?exp=#{exp}&sig=#{sig}"}
    end
  end

  # When `:tuliprox_public_url` is configured, every Xtream provider's stream
  # URL is rewritten to point at the public Tuliprox hostname. The DB row
  # keeps an internal hostname (e.g. `http://tuliprox:8901`) for sync calls
  # over the docker network — those don't need to round-trip Cloudflare —
  # but the player needs a publicly reachable origin for its 302 target.
  defp public_base(provider) do
    case Application.get_env(:streamix, :tuliprox_public_url, "") do
      "" ->
        provider.url

      base when is_binary(base) ->
        base
    end
  end

  # Verifies that the token's user_id is authorized to access content from this provider.
  # A user can access a provider if:
  # 1. The provider is public or global (accessible to everyone)
  # 2. The user_id matches the provider's owner
  defp authorized_for_provider?(_user_id, %{visibility: visibility})
       when visibility in [:public, :global],
       do: true

  defp authorized_for_provider?(user_id, %{user_id: provider_user_id})
       when is_integer(user_id) and user_id == provider_user_id,
       do: true

  defp authorized_for_provider?(_user_id, _provider), do: false
end
