defmodule StreamixWeb.StreamToken.Resolver do
  @moduledoc """
  Verifies signed stream tokens and resolves them to the actual upstream
  URL (signing is in `StreamixWeb.StreamToken.Signer`).

  Two flows live here:

  * **Token verification** — `verify_and_get_url/2` checks signature +
    expiry then dispatches by token shape (`"url"` vs the content variants
    `"movie"`/`"episode"`/`"channel"`).
  * **Pre-flight URL resolution** — `upstream_url/4` returns the same URL
    the verifier would, without round-tripping through the signed token.
    Used by `PlayerLive.mount/3` to prewarm the redirect-chain resolver.

  Authorization (premium gate, provider visibility, integration-bypass)
  is enforced in both flows — they share the same checks via the
  private `authorize_*` helpers below.
  """

  require Logger

  alias Streamix.Access
  alias Streamix.Accounts
  alias Streamix.Gindex
  alias StreamixWeb.UrlValidator

  # Token expires in 2 hours (reduced from 24h for security).
  @token_max_age 7_200

  # Gateway resources of an opened HLS session; see `authorize_xtream_hls/2`.
  @resource_token_max_age 21_600

  @doc """
  Verifies a token and returns `{:ok, url, content_type, meta}` or `{:error, reason}`.
  See `StreamixWeb.StreamToken.verify_and_get_url/2` for the full contract.
  """
  def verify_and_get_url(token, opts \\ []) do
    external_bypass = Keyword.get(opts, :bypass_subscription, false)

    case Phoenix.Token.verify(StreamixWeb.Endpoint, "stream", token, max_age: @token_max_age) do
      {:ok, claims} -> dispatch_claims(claims, external_bypass)
      {:error, :expired} -> {:error, :token_expired}
      {:error, _reason} -> {:error, :invalid_token}
    end
  end

  @doc false
  def authorize_embedplay_movie(token) do
    with {:ok, %{type: "movie", id: id, user_id: user_id} = claims} <-
           Phoenix.Token.verify(StreamixWeb.Endpoint, "stream", token, max_age: @token_max_age),
         true <- is_integer(id) and id > 0,
         %{provider: %{provider_type: :embedplay, is_active: true} = provider} = movie <-
           Streamix.Playback.get_movie_for_stream(id),
         {:ok, ^movie, _provider_id} <-
           authorize_resolved_content(
             provider,
             user_id,
             movie,
             effective_bypass(claims, false),
             fn ->
               {:ok, movie}
             end
           ) do
      {:ok, movie}
    else
      {:error, :expired} -> {:error, :token_expired}
      {:error, reason} when reason in [:subscription_required, :unauthorized] -> {:error, reason}
      _ -> {:error, :invalid_token}
    end
  end

  @doc """
  Authorizes a movie, episode or live channel token for the Xtream HLS
  gateway.

  The checks are those of the progressive movie/episode/channel flow — signature,
  two-hour age, ownership or visibility, the global-content subscription
  policy and the API-key bypass (the token's own claim, or
  `bypass_subscription: true` from a request carrying a valid key) — plus
  the provider's operator switch (`:provider_disabled`) and automatic health
  (`:provider_degraded`). Content the delivery policy does not route to HLS
  fails with `:stream_format_mismatch`.

  Returns `{:ok, %{content: {:movie | :episode | :channel, id}, provider_id:,
  url:}}`. `url` embeds the account credentials: it is for the server-side
  gateway only and must never reach a client or a log line.

  `stage: :start` (the default) is the master request that starts a
  playback: the delivery is checked, a bypass is audited, and the token's
  two-hour age applies. `stage: :resource` is a playlist, key or segment of
  an already opened session: the session itself pins the item, a bypass is
  not audited per segment, and the token is accepted for
  #{div(21_600, 3_600)} hours, because a VOD player loads its playlists once
  and keeps requesting segments with the start token for as long as the
  movie (and any pause) lasts, and a live player keeps refreshing its
  playlist with it. Past that cap the request fails with `token_expired`,
  and the player re-requests its stream URL (the web player does this on its
  own; a TV client re-requests `/api/v1/catalog/channels/:id/stream`). Every
  other check still runs on each request; no token is ever unbounded.
  """
  def authorize_xtream_hls(token, opts \\ []) do
    stage = Keyword.get(opts, :stage, :start)

    with {:ok, item} <- authorize_xtream_item(token, stage, opts),
         {:ok, url} <- hls_root(stage, item) do
      {:ok, %{content: {item.type, item.id}, provider_id: item.provider_id, url: url}}
    end
  end

  @doc """
  Authorizes a movie or episode token for the direct-client route of a
  `direct_client_playback` provider, with the checks of
  `authorize_xtream_hls/2` at the start stage.

  Returns `{:ok, %{content:, provider_id:, url:}}` where `url` is the final
  CDN URL the client is redirected to — resolved server-side, `https`, and
  never containing the account password. Items the probe decided to serve
  through the HLS gateway fail with `:stream_format_mismatch`.
  """
  def authorize_xtream_direct(token, opts \\ []) do
    with {:ok, item} <- authorize_xtream_item(token, :start, opts),
         {:ok, {:direct, url, _extension}} <-
           delivery(item) do
      {:ok, %{content: {item.type, item.id}, provider_id: item.provider_id, url: url}}
    else
      {:ok, _hls_or_ts} -> {:error, :stream_format_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Authorizes a movie or episode token and returns the gateway route its
  player must use: `{:ok, :hls}` or `{:ok, {:direct, extension}}`. The token
  proxy uses it to redirect a player that holds an older proxy URL for an
  item that a probe decides at play time. A failed probe returns its reason
  (`:upstream_not_found` for a dead item).
  """
  def authorize_xtream_route(token, opts \\ []) do
    with {:ok, item} <- authorize_xtream_item(token, :start, opts) do
      case delivery(item) do
        {:ok, {:hls, _root}} -> {:ok, :hls}
        {:ok, {:direct, _url, extension}} -> {:ok, {:direct, extension}}
        {:ok, :ts} -> {:error, :stream_format_mismatch}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Every gateway check except the delivery decision: the probe runs only
  # for a caller that is already authorized and whose provider is usable.
  defp authorize_xtream_item(token, stage, opts) do
    with {:ok, claims} <- verify_claims(token, token_max_age(stage)),
         {:ok, type, id} <- content_claim(claims),
         {:ok, content, provider} <- stream_content(type, id),
         :ok <- xtream_provider(provider),
         bypass = authorize_bypass(claims, Keyword.put(opts, :audit, stage == :start)),
         {:ok, _url, provider_id} <-
           build_content_url(
             provider,
             claims.user_id,
             content,
             content_path(type),
             upstream_stream_id(type, content),
             Map.get(content, :container_extension),
             bypass
           ),
         :ok <- provider_available(provider) do
      {:ok, %{type: type, id: id, content: content, provider: provider, provider_id: provider_id}}
    end
  end

  # Resource requests are pinned to the item by their session, so only the
  # start of a playback consults the delivery decision (and never probes).
  defp hls_root(:resource, _item), do: {:ok, nil}

  defp hls_root(:start, item) do
    case delivery(item) do
      {:ok, {:hls, root_url}} -> {:ok, root_url}
      {:ok, _direct_or_ts} -> {:error, :stream_format_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delivery(item),
    do: Streamix.Playback.resolve_xtream_delivery(item.provider, item.type, item.content)

  defp xtream_provider(%{provider_type: type}) when type in [:xtream, "xtream"], do: :ok
  defp xtream_provider(_provider), do: {:error, :stream_format_mismatch}

  defp token_max_age(:resource), do: @resource_token_max_age
  defp token_max_age(_stage), do: @token_max_age

  defp verify_claims(token, max_age) do
    case Phoenix.Token.verify(StreamixWeb.Endpoint, "stream", token, max_age: max_age) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:ok, _claims} -> {:error, :invalid_token}
      {:error, :expired} -> {:error, :token_expired}
      {:error, _reason} -> {:error, :invalid_token}
    end
  end

  defp content_claim(%{type: "movie", id: id, user_id: _user_id}) when is_integer(id) and id > 0,
    do: {:ok, :movie, id}

  defp content_claim(%{type: "episode", id: id, user_id: _user_id})
       when is_integer(id) and id > 0,
       do: {:ok, :episode, id}

  defp content_claim(%{type: "channel", id: id, user_id: _user_id})
       when is_integer(id) and id > 0,
       do: {:ok, :channel, id}

  defp content_claim(_claims), do: {:error, :invalid_token}

  defp stream_content(:channel, id) do
    case Streamix.Playback.get_live_channel_for_stream(id) do
      %{provider: %{} = provider} = channel -> {:ok, channel, provider}
      _ -> {:error, :not_found}
    end
  end

  defp stream_content(:movie, id) do
    case Streamix.Playback.get_movie_for_stream(id) do
      %{provider: %{} = provider} = movie -> {:ok, movie, provider}
      _ -> {:error, :not_found}
    end
  end

  defp stream_content(:episode, id) do
    case Streamix.Playback.get_episode_for_stream(id) do
      %{season: %{series: %{provider: %{} = provider}}} = episode -> {:ok, episode, provider}
      _ -> {:error, :not_found}
    end
  end

  defp content_path(:movie), do: "movie"
  defp content_path(:episode), do: "series"
  defp content_path(:channel), do: "live"

  defp upstream_stream_id(:movie, movie), do: movie.stream_id
  defp upstream_stream_id(:episode, episode), do: episode.episode_id
  defp upstream_stream_id(:channel, channel), do: channel.stream_id

  defp authorize_bypass(claims, opts) do
    external_bypass = Keyword.get(opts, :bypass_subscription, false)

    if Keyword.get(opts, :audit, true),
      do: effective_bypass(claims, external_bypass),
      else: external_bypass or Map.get(claims, :bypass, false)
  end

  # The operator's switch and the automatic health state, checked after
  # authorization so an unauthorized caller learns nothing about either.
  defp provider_available(%{is_active: false}), do: {:error, :provider_disabled}
  defp provider_available(%{health_status: :degraded}), do: {:error, :provider_degraded}
  defp provider_available(_provider), do: :ok

  @doc """
  Returns the raw upstream URL that the given content would resolve to
  if its token were verified. Authorization is enforced.
  """
  def upstream_url(type, id, user_id, opts \\ [])
      when type in ["movie", "episode", "channel"] and is_integer(id) do
    bypass = Keyword.get(opts, :bypass_subscription, false)

    case get_stream_url(type, id, user_id, bypass) do
      {:ok, url, _provider_id} -> {:ok, url}
      other -> other
    end
  end

  # ----- Token dispatch -----

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
      {:ok, url, "url", %{content_id: nil, provider_id: provider_id}}
    end
  end

  defp dispatch_claims(%{type: "url"}, _external_bypass), do: {:error, :invalid_token}

  defp dispatch_claims(%{type: type, id: id, user_id: user_id} = claims, external_bypass) do
    bypass = effective_bypass(claims, external_bypass)

    with {:ok, url, ^type, provider_id} <- handle_content_token(type, id, user_id, bypass) do
      {:ok, url, type, %{content_id: id, provider_id: provider_id}}
    end
  end

  defp dispatch_claims(_claims, _external_bypass), do: {:error, :invalid_token}

  defp effective_bypass(claims, external_bypass) do
    bypass = external_bypass or Map.get(claims, :bypass, false)

    if bypass, do: audit_bypass(claims, external_bypass)

    bypass
  end

  # Subscription/premium checks were skipped for this resolve. Emitted to
  # both Logger and Telemetry so dashboards can surface bypass rates.
  # Never log the full URL — only the metadata needed to trace the
  # resolve back to its origin.
  defp audit_bypass(claims, external_bypass) do
    metadata = %{
      type: Map.get(claims, :type),
      content_id: Map.get(claims, :id),
      user_id: Map.get(claims, :user_id),
      provider_id: Map.get(claims, :provider_id),
      claim_bypass: Map.get(claims, :bypass, false),
      external_bypass: external_bypass
    }

    Logger.info("StreamToken bypass used: #{inspect(metadata)}")

    :telemetry.execute(
      [:streamix, :stream_token, :bypass_used],
      %{count: 1},
      metadata
    )
  end

  # ----- URL-token path -----

  defp handle_url_token(url, user_id, provider_id, premium_required, bypass_subscription) do
    case Streamix.Providers.get_provider(provider_id) do
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
        if Access.plays_global_content?(user, provider) do
          validate_direct_url(url)
        else
          {:error, :subscription_required}
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

  defp validate_direct_url(url) do
    case UrlValidator.validate_url(url) do
      :ok -> {:ok, url, "url"}
      {:error, :unsafe_url} -> {:error, :unsafe_url}
    end
  end

  # ----- Content-token path -----

  defp handle_content_token(type, id, user_id, bypass_subscription) do
    case get_stream_url(type, id, user_id, bypass_subscription) do
      {:ok, url, provider_id} -> {:ok, url, type, provider_id}
      error -> error
    end
  end

  defp get_stream_url("movie", id, user_id, bypass) do
    case Streamix.Playback.get_movie_for_stream(id) do
      nil -> {:error, :not_found}
      movie -> build_movie_url(movie.provider, user_id, movie, bypass)
    end
  end

  defp get_stream_url("episode", id, user_id, bypass) do
    case Streamix.Playback.get_episode_for_stream(id) do
      nil ->
        {:error, :not_found}

      episode ->
        build_episode_url(episode.season.series.provider, user_id, episode, bypass)
    end
  end

  defp get_stream_url("channel", id, user_id, bypass) do
    case Streamix.Playback.get_live_channel_for_stream(id) do
      nil ->
        {:error, :not_found}

      channel ->
        with {:ok, _url, _provider_id} = built <-
               build_content_url(
                 channel.provider,
                 user_id,
                 channel,
                 "live",
                 channel.stream_id,
                 "ts",
                 bypass
               ) do
          live_route(channel, built)
        end
    end
  end

  # Providers without `probe_live_delivery` keep the TS live path exactly as
  # it was. For the others, the (authorized) channel's probe decides: TS
  # stays here, HLS is redirected to the gateway, and a channel that is not
  # a stream (an embed page, a dead URL) is refused instead of proxied.
  defp live_route(channel, built) do
    case Streamix.Playback.xtream_live_mode(channel.provider) do
      :ts ->
        built

      :probe ->
        case Streamix.Playback.resolve_xtream_delivery(channel.provider, :channel, channel) do
          {:ok, :ts} -> built
          {:ok, {:hls, _root}} -> {:error, :hls_playback_required}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp build_movie_url(%{provider_type: :embedplay}, _user_id, _movie, _bypass),
    do: {:error, :embedplay_playback_required}

  defp build_movie_url(provider, user_id, %{gindex_path: path} = movie, bypass)
       when is_binary(path) and path != "" do
    if gindex_provider?(provider) do
      authorize_resolved_content(provider, user_id, movie, bypass, fn ->
        Gindex.get_movie_url(movie.id)
      end)
    else
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

  defp build_movie_url(provider, user_id, movie, bypass) do
    case Streamix.Playback.xtream_delivery(provider, movie) do
      {:hls, _extension} ->
        {:error, :hls_playback_required}

      :probe ->
        {:error, :delivery_probe_required}

      :proxy ->
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

  defp build_episode_url(provider, user_id, %{gindex_path: path} = episode, bypass)
       when is_binary(path) and path != "" do
    if gindex_provider?(provider) do
      authorize_resolved_content(provider, user_id, episode, bypass, fn ->
        Gindex.get_episode_url(episode.id)
      end)
    else
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

  # HLS items are not byte-range files, so the progressive proxy never gets
  # their URL: the token proxy redirects them to the HLS gateway instead. A
  # probed provider's item is redirected to whichever route its probe picks.
  defp build_episode_url(provider, user_id, episode, bypass) do
    case Streamix.Playback.xtream_delivery(provider, episode) do
      {:hls, _extension} ->
        {:error, :hls_playback_required}

      :probe ->
        {:error, :delivery_probe_required}

      :proxy ->
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

  defp authorize_resolved_content(provider, user_id, content, bypass, fetch_url) do
    cond do
      Access.global_content?(provider) ->
        authorize_global_resolved_content(provider, user_id, content, bypass, fetch_url)

      authorized_for_provider?(user_id, provider) ->
        resolve_authorized_content(provider, fetch_url)

      true ->
        {:error, :unauthorized}
    end
  end

  defp authorize_global_resolved_content(provider, _user_id, _content, true, fetch_url) do
    resolve_authorized_content(provider, fetch_url)
  end

  defp authorize_global_resolved_content(_provider, nil, _content, _bypass, _fetch_url) do
    {:error, :subscription_required}
  end

  defp authorize_global_resolved_content(provider, user_id, _content, _bypass, fetch_url) do
    case Accounts.get_user(user_id) do
      nil ->
        {:error, :subscription_required}

      user ->
        # Gate on the provider, never on the content struct. An Episode carries
        # no provider_id and no provider association, so Access.global_content?/1
        # falls through to its catch-all `false` clause and
        # plays_global_content?/2 then returns true for everyone.
        if Access.plays_global_content?(user, provider) do
          resolve_authorized_content(provider, fetch_url)
        else
          {:error, :subscription_required}
        end
    end
  end

  defp resolve_authorized_content(provider, fetch_url) do
    case fetch_url.() do
      {:ok, url} -> {:ok, url, provider.id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_content_url(
         %{provider_type: provider_type},
         _user_id,
         _content,
         _content_path,
         _stream_id,
         _extension,
         _bypass
       )
       when provider_type in [:torrent, "torrent"],
       do: {:error, :torrent_playback_required}

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
         _content,
         content_path,
         stream_id,
         extension,
         _bypass
       ) do
    case Accounts.get_user(user_id) do
      nil ->
        {:error, :subscription_required}

      user ->
        # See the note above: the gate must take the provider, not the content.
        if Access.plays_global_content?(user, provider) do
          build_provider_content_url(provider, content_path, stream_id, extension)
        else
          {:error, :subscription_required}
        end
    end
  end

  defp build_provider_content_url(provider, "movie", stream_id, extension) do
    ext = extension || "mp4"
    url = "#{provider.url}/movie/#{provider.username}/#{provider.password}/#{stream_id}.#{ext}"
    {:ok, url, provider.id}
  end

  defp build_provider_content_url(provider, "series", stream_id, extension) do
    ext = extension || "mp4"
    url = "#{provider.url}/series/#{provider.username}/#{provider.password}/#{stream_id}.#{ext}"
    {:ok, url, provider.id}
  end

  defp build_provider_content_url(provider, "live", stream_id, _extension) do
    # Use .ts for direct MPEG-TS streaming (not .m3u8 which is a playlist)
    # to avoid mixed content issues with HLS segment URLs.
    url = "#{provider.url}/live/#{provider.username}/#{provider.password}/#{stream_id}.ts"
    {:ok, url, provider.id}
  end

  defp gindex_provider?(%{provider_type: provider_type}), do: provider_type in [:gindex, "gindex"]
  defp gindex_provider?(_provider), do: false

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
