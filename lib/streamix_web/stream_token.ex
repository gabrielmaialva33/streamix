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
  Verifies a token and returns the actual stream URL if valid.
  Returns {:ok, url} or {:error, reason}.
  """
  def verify_and_get_url(token) do
    case Phoenix.Token.verify(StreamixWeb.Endpoint, "stream", token, max_age: @token_max_age) do
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

        url =
          "#{provider.url}/live/#{provider.username}/#{provider.password}/#{channel.stream_id}.m3u8"

        {:ok, url}
    end
  end
end
