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
  """
  def sign_url(url, user_id) when is_binary(url) do
    case UrlValidator.validate_url(url) do
      :ok ->
        data = %{type: "url", url: url, user_id: user_id}
        Phoenix.Token.sign(StreamixWeb.Endpoint, "stream", data)

      {:error, :unsafe_url} ->
        {:error, :unsafe_url}
    end
  end

  @doc """
  Verifies a token and returns the actual stream URL if valid.
  Returns {:ok, url, content_type} or {:error, reason}.

  `content_type` is "channel", "movie", "episode", or "url".

  The embedded user_id is checked against provider ownership:
  - If user_id is present, the content's provider must belong to that user
    or be a public/global provider.
  - If user_id is nil (public catalog token), the provider must be public/global.
  """
  def verify_and_get_url(token) do
    case verify_token(token) do
      {:ok, %{type: "url", url: url}} ->
        validate_direct_url(url)

      {:ok, %{type: type, id: id, user_id: user_id}} ->
        handle_content_token(type, id, user_id)

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

  defp handle_content_token(type, id, user_id) do
    case get_stream_url(type, id, user_id) do
      {:ok, url} -> {:ok, url, type}
      error -> error
    end
  end

  defp get_stream_url("movie", id, user_id) do
    case Iptv.get_movie(id) do
      nil ->
        {:error, :not_found}

      movie ->
        movie = Repo.preload(movie, :provider)
        provider = movie.provider

        if authorized_for_provider?(user_id, provider) do
          ext = movie.container_extension || "mp4"

          url =
            "#{provider.url}/movie/#{provider.username}/#{provider.password}/#{movie.stream_id}.#{ext}"

          {:ok, url}
        else
          {:error, :unauthorized}
        end
    end
  end

  defp get_stream_url("episode", id, user_id) do
    case Iptv.get_episode(id) do
      nil ->
        {:error, :not_found}

      episode ->
        episode = Repo.preload(episode, season: [series: :provider])
        provider = episode.season.series.provider

        if authorized_for_provider?(user_id, provider) do
          ext = episode.container_extension || "mp4"

          url =
            "#{provider.url}/series/#{provider.username}/#{provider.password}/#{episode.episode_id}.#{ext}"

          {:ok, url}
        else
          {:error, :unauthorized}
        end
    end
  end

  defp get_stream_url("channel", id, user_id) do
    case Iptv.get_live_channel(id) do
      nil ->
        {:error, :not_found}

      channel ->
        channel = Repo.preload(channel, :provider)
        provider = channel.provider

        if authorized_for_provider?(user_id, provider) do
          # Use .ts for direct MPEG-TS streaming (not .m3u8 which is a playlist)
          # This avoids mixed content issues with HLS segment URLs
          url =
            "#{provider.url}/live/#{provider.username}/#{provider.password}/#{channel.stream_id}.ts"

          {:ok, url}
        else
          {:error, :unauthorized}
        end
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
