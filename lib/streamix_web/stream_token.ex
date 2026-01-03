defmodule StreamixWeb.StreamToken do
  @moduledoc """
  Generates and verifies signed tokens for streaming content.

  This prevents exposing provider credentials in API responses.
  Instead of returning URLs with embedded username/password, we return
  a signed token that can be exchanged for the actual stream URL server-side.
  """

  alias Streamix.Iptv
  alias Streamix.Repo

  # Token expires in 24 hours
  @token_max_age 86_400

  @doc """
  Generates a signed token for accessing a movie stream.
  """
  def sign_movie(movie_id) when is_integer(movie_id) do
    sign_content("movie", movie_id)
  end

  @doc """
  Generates a signed token for accessing an episode stream.
  """
  def sign_episode(episode_id) when is_integer(episode_id) do
    sign_content("episode", episode_id)
  end

  @doc """
  Generates a signed token for accessing a channel stream.
  """
  def sign_channel(channel_id) when is_integer(channel_id) do
    sign_content("channel", channel_id)
  end

  @doc """
  Generates a signed token for proxying an external URL.
  Used for GIndex and other external sources that need CORS headers.
  Token expires in 1 hour for security.
  """
  def sign_url(url) when is_binary(url) do
    data = %{type: "url", url: url}
    Phoenix.Token.sign(StreamixWeb.Endpoint, "stream", data)
  end

  @doc """
  Verifies a token and returns the actual stream URL if valid.
  Returns {:ok, url} or {:error, reason}.
  """
  def verify_and_get_url(token) do
    case Phoenix.Token.verify(StreamixWeb.Endpoint, "stream", token, max_age: @token_max_age) do
      {:ok, %{type: "url", url: url}} ->
        # Direct URL token (for GIndex and external sources)
        {:ok, url}

      {:ok, %{type: type, id: id}} ->
        get_stream_url(type, id)

      {:error, :expired} ->
        {:error, :token_expired}

      {:error, _reason} ->
        {:error, :invalid_token}
    end
  end

  # Private functions

  defp sign_content(type, id) do
    data = %{type: type, id: id}
    Phoenix.Token.sign(StreamixWeb.Endpoint, "stream", data)
  end

  defp get_stream_url("movie", id) do
    case Iptv.get_movie(id) do
      nil ->
        {:error, :not_found}

      movie ->
        movie = Repo.preload(movie, :provider)
        provider = movie.provider
        ext = movie.container_extension || "mp4"

        url =
          "#{provider.url}/movie/#{provider.username}/#{provider.password}/#{movie.stream_id}.#{ext}"

        {:ok, url}
    end
  end

  defp get_stream_url("episode", id) do
    case Iptv.get_episode(id) do
      nil ->
        {:error, :not_found}

      episode ->
        episode = Repo.preload(episode, season: [series: :provider])
        provider = episode.season.series.provider
        ext = episode.container_extension || "mp4"

        url =
          "#{provider.url}/series/#{provider.username}/#{provider.password}/#{episode.episode_id}.#{ext}"

        {:ok, url}
    end
  end

  defp get_stream_url("channel", id) do
    case Iptv.get_channel(id) do
      nil ->
        {:error, :not_found}

      channel ->
        channel = Repo.preload(channel, :provider)
        provider = channel.provider

        # Use .ts for direct MPEG-TS streaming (not .m3u8 which is a playlist)
        # This avoids mixed content issues with HLS segment URLs
        url =
          "#{provider.url}/live/#{provider.username}/#{provider.password}/#{channel.stream_id}.ts"

        {:ok, url}
    end
  end
end
