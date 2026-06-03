defmodule StreamixWeb.StreamToken.Signer do
  @moduledoc """
  Mints signed stream tokens.

  Split out of `StreamixWeb.StreamToken` so the signing surface stays
  small (4 public entry points) and is easy to reason about
  independently from the verification + URL-resolution path. The token
  payload shape is the contract between this module and
  `StreamixWeb.StreamToken.Resolver`.
  """

  alias StreamixWeb.UrlValidator

  @doc "Sign a movie stream token. See `StreamixWeb.StreamToken` for opts."
  def sign_movie(movie_id, user_id, opts \\ []) when is_integer(movie_id) do
    sign_content("movie", movie_id, user_id, opts)
  end

  @doc "Sign an episode stream token."
  def sign_episode(episode_id, user_id, opts \\ []) when is_integer(episode_id) do
    sign_content("episode", episode_id, user_id, opts)
  end

  @doc "Sign a channel stream token."
  def sign_channel(channel_id, user_id, opts \\ []) when is_integer(channel_id) do
    sign_content("channel", channel_id, user_id, opts)
  end

  @doc """
  Sign a direct-URL token (GIndex, external CORS-aware sources).

  Refuses to sign if the URL doesn't pass `UrlValidator`.
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

  defp sign_content(type, id, user_id, opts) do
    data = %{
      type: type,
      id: id,
      user_id: user_id,
      bypass: Keyword.get(opts, :bypass_subscription, false)
    }

    Phoenix.Token.sign(StreamixWeb.Endpoint, "stream", data)
  end
end
