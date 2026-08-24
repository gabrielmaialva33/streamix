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
        build_content_url(
          channel.provider,
          user_id,
          channel,
          "live",
          channel.stream_id,
          "ts",
          bypass
        )
    end
  end

  defp build_movie_url(provider, user_id, %{gindex_path: path} = movie, bypass)
       when is_binary(path) and path != "" do
    if gindex_provider?(provider) do
      build_gindex_content_url(provider, user_id, movie, bypass, fn ->
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

  defp build_episode_url(provider, user_id, %{gindex_path: path} = episode, bypass)
       when is_binary(path) and path != "" do
    if gindex_provider?(provider) do
      build_gindex_content_url(provider, user_id, episode, bypass, fn ->
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

  defp build_episode_url(provider, user_id, episode, bypass) do
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

  defp build_gindex_content_url(provider, user_id, content, bypass, fetch_url) do
    cond do
      Access.global_content?(provider) ->
        build_global_gindex_content_url(provider, user_id, content, bypass, fetch_url)

      authorized_for_provider?(user_id, provider) ->
        fetch_gindex_content_url(provider, fetch_url)

      true ->
        {:error, :unauthorized}
    end
  end

  defp build_global_gindex_content_url(provider, _user_id, _content, true, fetch_url) do
    fetch_gindex_content_url(provider, fetch_url)
  end

  defp build_global_gindex_content_url(_provider, nil, _content, _bypass, _fetch_url) do
    {:error, :subscription_required}
  end

  defp build_global_gindex_content_url(provider, user_id, content, _bypass, fetch_url) do
    case Accounts.get_user(user_id) do
      nil ->
        {:error, :subscription_required}

      user ->
        if Access.plays_global_content?(user, content) do
          fetch_gindex_content_url(provider, fetch_url)
        else
          {:error, :subscription_required}
        end
    end
  end

  defp fetch_gindex_content_url(provider, fetch_url) do
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
        if Access.plays_global_content?(user, content) do
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
