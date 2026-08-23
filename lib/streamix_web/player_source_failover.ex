defmodule StreamixWeb.PlayerSourceFailover do
  @moduledoc """
  Selects and resolves the next equivalent playback source for web players.

  Equivalent catalog discovery stays inside the IPTV facade, authorization is
  rechecked per candidate, and only a fresh signed Streamix URL leaves this
  boundary. Both the standalone player and Watch Party host use this service so
  their failover order and exclusion semantics remain identical.
  """

  alias Streamix.{Access, Iptv}
  alias StreamixWeb.PlayerComponents.Metadata
  alias StreamixWeb.PlayerHelpers

  @type source :: %{
          content: map(),
          content_type: String.t(),
          provider: map(),
          stream_url: String.t()
        }

  @doc "Returns the next authorized source and the expanded attempted-id set."
  @spec next(atom() | String.t(), map(), map(), MapSet.t()) ::
          {:ok, source(), MapSet.t()} | {:error, :no_sources, MapSet.t()}
  def next(type, content, user, attempted_ids) do
    attempted_ids = MapSet.put(attempted_ids, content.id)

    type
    |> PlayerHelpers.failover_sources(content, user.id)
    |> Enum.reduce_while({:error, :no_sources, attempted_ids}, fn candidate, result ->
      attempted = elem(result, 2)

      if MapSet.member?(attempted, candidate.id) do
        {:cont, result}
      else
        attempted = MapSet.put(attempted, candidate.id)

        if Access.plays_global_content?(user, candidate.provider) do
          case resolve_candidate(candidate, user.id) do
            {:ok, source} -> {:halt, {:ok, source, attempted}}
            {:error, _reason} -> {:cont, {:error, :no_sources, attempted}}
          end
        else
          {:cont, {:error, :no_sources, attempted}}
        end
      end
    end)
  end

  @doc "Builds the credential-free browser payload for a selected source."
  @spec payload(source(), number(), non_neg_integer()) :: map()
  def payload(source, position, count) do
    content_type = content_type_atom(source.content_type)
    provider_type = source.provider.provider_type

    %{
      content_id: source.content.id,
      provider_id: source.provider.id,
      provider_name: source.provider.name,
      source_type: to_string(provider_type),
      stream_url: source.stream_url,
      proxy_url: Metadata.proxy_url(source.stream_url, content_type),
      stream_type: Metadata.stream_type_hint(content_type, source.content, provider_type),
      resume_time: normalize_position(position),
      failover_count: count,
      message: "Fonte alterada para #{source.provider.name}. Retomando a reprodução."
    }
  end

  defp resolve_candidate(%{content_type: "episode", id: id} = candidate, user_id) do
    case Iptv.get_playable_episode(user_id, id) do
      nil ->
        {:error, :not_found}

      episode ->
        provider = episode.season.series.provider
        resolve_stream(candidate, episode, provider, user_id)
    end
  end

  defp resolve_candidate(candidate, user_id) do
    resolve_stream(candidate, candidate.content, candidate.provider, user_id)
  end

  defp resolve_stream(candidate, content, provider, user_id) do
    case PlayerHelpers.resolve_stream_url(candidate.content_type, content, provider, user_id) do
      {:ok, stream_url} ->
        {:ok,
         candidate
         |> Map.put(:content, content)
         |> Map.put(:provider, provider)
         |> Map.put(:stream_url, stream_url)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_type_atom("movie"), do: :movie
  defp content_type_atom("episode"), do: :episode
  defp content_type_atom("gindex"), do: :gindex
  defp content_type_atom("gindex_episode"), do: :gindex_episode
  defp content_type_atom(type) when is_atom(type), do: type
  defp content_type_atom(_type), do: :movie

  defp normalize_position(value) when is_integer(value) and value >= 0, do: value * 1.0
  defp normalize_position(value) when is_float(value) and value >= 0, do: value
  defp normalize_position(_value), do: 0.0
end
