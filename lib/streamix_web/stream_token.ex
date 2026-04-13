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
  alias Streamix.Accounts.User
  alias Streamix.Iptv
  alias Streamix.Repo
  alias StreamixWeb.UrlValidator

  # Token expires in 2 hours (reduced from 24h for security)
  @token_max_age 7_200

  @doc """
  Generates a signed token for accessing a movie stream.
  The `user_id` is embedded in the token and verified on consumption.
  Pass `nil` for public/global provider content (catalog API).
  """
  def sign_movie(movie_id, user_id) when is_integer(movie_id) do
    sign_content("movie", movie_id, user_id)
  end

  @doc """
  Generates a signed token for accessing an episode stream.
  The `user_id` is embedded in the token and verified on consumption.
  Pass `nil` for public/global provider content (catalog API).
  """
  def sign_episode(episode_id, user_id) when is_integer(episode_id) do
    sign_content("episode", episode_id, user_id)
  end

  @doc """
  Generates a signed token for accessing a channel stream.
  The `user_id` is embedded in the token and verified on consumption.
  Pass `nil` for public/global provider content (catalog API).
  """
  def sign_channel(channel_id, user_id) when is_integer(channel_id) do
    sign_content("channel", channel_id, user_id)
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

        data = %{
          type: "url",
          url: url,
          user_id: user_id,
          provider_id: provider_id,
          premium_required: premium_required
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
  """
  def verify_and_get_url(token) do
    case verify_token(token) do
      {:ok,
       %{
         type: "url",
         url: url,
         user_id: user_id,
         provider_id: provider_id,
         premium_required: premium_required
       }} ->
        with {:ok, url, "url"} <- handle_url_token(url, user_id, provider_id, premium_required) do
          {:ok, url, "url", %{content_id: nil}}
        end

      {:ok, %{type: "url", url: _url, user_id: _user_id}} ->
        {:error, :invalid_token}

      {:ok, %{type: "url", url: _url}} ->
        {:error, :invalid_token}

      {:ok, %{type: type, id: id, user_id: user_id}} ->
        with {:ok, url, ^type} <- handle_content_token(type, id, user_id) do
          {:ok, url, type, %{content_id: id}}
        end

      {:ok, %{type: _type, id: _id}} ->
        {:error, :invalid_token}

      {:error, :expired} ->
        {:error, :token_expired}

      {:error, _reason} ->
        {:error, :invalid_token}
    end
  end

  # Private functions

  defp sign_content(type, id, user_id) do
    data = %{type: type, id: id, user_id: user_id}
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

  defp handle_url_token(url, user_id, provider_id, premium_required) do
    case Iptv.get_provider(provider_id) do
      nil ->
        {:error, :invalid_token}

      provider ->
        if premium_required and not Access.global_content?(provider) do
          {:error, :invalid_token}
        else
          authorize_url_token(url, user_id, provider)
        end
    end
  end

  defp authorize_url_token(url, user_id, provider) do
    cond do
      Access.global_content?(provider) ->
        user_has_global_access?(user_id, provider, url)

      provider.visibility in [:public, "public"] ->
        validate_direct_url(url)

      provider.visibility in [:private, "private"] ->
        authorized_private_url_token?(url, user_id, provider)

      true ->
        {:error, :invalid_token}
    end
  end

  defp user_has_global_access?(nil, _provider, _url), do: {:error, :subscription_required}

  defp user_has_global_access?(user_id, provider, url) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :subscription_required}

      %User{} = user ->
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
    case Repo.get(User, user_id) do
      nil ->
        {:error, :invalid_token}

      %User{} ->
        if user_id == provider_user_id do
          validate_direct_url(url)
        else
          {:error, :unauthorized}
        end
    end
  end

  defp authorized_private_url_token?(_url, _user_id, _provider), do: {:error, :invalid_token}

  defp handle_content_token(type, id, user_id) do
    case get_stream_url(type, id, user_id) do
      {:ok, url} -> {:ok, url, type}
      error -> error
    end
  end

  defp get_stream_url("movie", id, user_id) do
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
          movie.container_extension
        )
    end
  end

  defp get_stream_url("episode", id, user_id) do
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
          episode.container_extension
        )
    end
  end

  defp get_stream_url("channel", id, user_id) do
    case Iptv.get_live_channel_for_stream(id) do
      nil ->
        {:error, :not_found}

      channel ->
        provider = channel.provider

        build_content_url(provider, user_id, channel, "live", channel.stream_id, "ts")
    end
  end

  defp build_content_url(provider, user_id, content, content_path, stream_id, extension) do
    cond do
      Access.global_content?(provider) ->
        build_global_content_url(provider, user_id, content, content_path, stream_id, extension)

      authorized_for_provider?(user_id, provider) ->
        build_provider_content_url(provider, content_path, stream_id, extension)

      true ->
        {:error, :unauthorized}
    end
  end

  defp build_global_content_url(_provider, nil, _content, _content_path, _stream_id, _extension) do
    {:error, :subscription_required}
  end

  defp build_global_content_url(provider, user_id, content, content_path, stream_id, extension) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :subscription_required}

      %User{} = user ->
        if Access.can_play_global_content?(user, content) do
          build_provider_content_url(provider, content_path, stream_id, extension)
        else
          {:error, :subscription_required}
        end
    end
  end

  defp build_provider_content_url(provider, "movie", stream_id, extension) do
    ext = extension || "mp4"
    url = "#{provider.url}/movie/#{provider.username}/#{provider.password}/#{stream_id}.#{ext}"
    {:ok, url}
  end

  defp build_provider_content_url(provider, "series", stream_id, extension) do
    ext = extension || "mp4"
    url = "#{provider.url}/series/#{provider.username}/#{provider.password}/#{stream_id}.#{ext}"
    {:ok, url}
  end

  defp build_provider_content_url(provider, "live", stream_id, _extension) do
    # Use .ts for direct MPEG-TS streaming (not .m3u8 which is a playlist)
    # This avoids mixed content issues with HLS segment URLs
    url = "#{provider.url}/live/#{provider.username}/#{provider.password}/#{stream_id}.ts"
    {:ok, url}
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
