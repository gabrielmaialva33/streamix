defmodule StreamixWeb.PlayerSourceFailover do
  @moduledoc """
  Selects and resolves the next equivalent playback source for web players.

  Equivalent catalog discovery stays inside the IPTV facade, authorization is
  rechecked per candidate, and only a fresh signed Streamix URL leaves this
  boundary. Both the standalone player and Watch Party host use this service so
  their failover order and exclusion semantics remain identical.
  """

  alias Streamix.Access
  alias StreamixWeb.PlayerComponents.Metadata
  alias StreamixWeb.PlayerHelpers

  @max_request_id_bytes 128
  @request_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

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
    |> Enum.reduce_while(
      {:error, :no_sources, attempted_ids},
      &select_candidate(&1, &2, user)
    )
  end

  defp select_candidate(candidate, result, user) do
    attempted = elem(result, 2)

    if MapSet.member?(attempted, candidate.id) do
      {:cont, result}
    else
      resolve_untried_candidate(candidate, attempted, user)
    end
  end

  defp resolve_untried_candidate(candidate, attempted, user) do
    attempted = MapSet.put(attempted, candidate.id)

    case authorized_source(candidate, user) do
      {:ok, source} -> {:halt, {:ok, source, attempted}}
      {:error, _reason} -> {:cont, {:error, :no_sources, attempted}}
    end
  end

  defp authorized_source(candidate, user) do
    if Access.plays_global_content?(user, candidate.provider) do
      resolve_candidate(candidate, user.id)
    else
      {:error, :unauthorized}
    end
  end

  @doc "Builds the credential-free browser payload for a selected source."
  @spec payload(source(), number(), non_neg_integer(), term()) :: map()
  def payload(source, position, count, request_id \\ nil) do
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
    |> with_request_id(request_id)
  end

  @doc "Normalizes the opaque browser request identifier used to reject stale replies."
  @spec normalize_request_id(term()) :: String.t() | nil
  def normalize_request_id(value) when is_binary(value) do
    request_id = String.trim(value)

    if byte_size(request_id) in 1..@max_request_id_bytes and
         Regex.match?(@request_id_pattern, request_id) do
      request_id
    end
  end

  def normalize_request_id(_value), do: nil

  @doc "Adds a validated request identifier to an outgoing browser payload."
  @spec with_request_id(map(), term()) :: map()
  def with_request_id(payload, request_id) when is_map(payload) do
    case normalize_request_id(request_id) do
      nil -> payload
      request_id -> Map.put(payload, :request_id, request_id)
    end
  end

  defp resolve_candidate(%{content_type: "episode", id: id} = candidate, user_id) do
    case Streamix.Playback.get_playable_episode(user_id, id) do
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
    case PlayerHelpers.resolve_stream_url(
           candidate.content_type,
           content,
           provider,
           user_id
         ) do
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
