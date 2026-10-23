defmodule Streamix.AI.UserAnalytics.Profile do
  @moduledoc false

  require Logger

  alias Streamix.Accounts
  alias Streamix.AI.Qdrant
  alias Streamix.Cache
  alias Streamix.Library
  alias Streamix.Library.Key

  @profile_ttl :timer.minutes(30)

  @doc """
  Computes a user's taste profile from their watch history.

  The profile is a weighted average of content embeddings:
  - More recent = higher weight
  - Completed = higher weight
  - Longer watch time = higher weight

  It needs the user's unlocked library key and is never persisted: a stored
  taste vector would let anyone with Qdrant access search for what the user
  watched. Returns {:ok, profile_vector} or {:error, reason}.
  """
  def compute_user_profile(%Key{} = key) do
    with {:ok, watched_content} <- get_watched_content_with_embeddings(key) do
      aggregate_profile(watched_content)
    end
  end

  @doc """
  Gets the user's profile vector, computing it if needed. It is cached in
  this node's memory only (`Streamix.Cache.fetch_personal/4`).
  """
  def get_user_profile(%Key{user_id: user_id} = key) do
    Cache.fetch_personal(user_id, :profile, @profile_ttl, fn ->
      case compute_user_profile(key) do
        {:ok, vector} -> vector
        {:error, _reason} -> nil
      end
    end)
  end

  defp get_watched_content_with_embeddings(%Key{user_id: user_id} = key) do
    history =
      key
      |> Library.list_watch_history_for_analytics(
        limit: 100,
        show_adult: show_adult_content?(user_id)
      )
      |> Enum.reject(&(&1.content_type == "live_channel"))

    case history do
      [] ->
        {:error, :no_history}

      history ->
        case map_embeddings(history) do
          [] -> {:error, :no_embeddings}
          content_with_vectors -> {:ok, content_with_vectors}
        end
    end
  end

  defp aggregate_profile(content_with_vectors) do
    total_weight =
      Enum.reduce(content_with_vectors, 0, fn %{weight: weight}, acc -> acc + weight end)

    case total_weight do
      0 ->
        {:error, :zero_weight}

      _ ->
        dimensions = length(hd(content_with_vectors).vector)
        profile = weighted_profile(content_with_vectors, dimensions, total_weight)
        {:ok, profile}
    end
  end

  defp calculate_weight(entry) do
    base_weight = 1.0
    days_ago = DateTime.diff(DateTime.utc_now(), entry.watched_at, :day)
    recency_factor = :math.exp(-days_ago / 30)
    completion_factor = if entry.completed, do: 1.5, else: 1.0
    duration = entry.duration_seconds || 0
    duration_factor = min(1 + duration / 3600, 2.0)

    base_weight * recency_factor * completion_factor * duration_factor
  end

  defp content_type_to_collection("movie"), do: "movies"
  defp content_type_to_collection("episode"), do: "series"
  defp content_type_to_collection(_), do: :skip

  # One Qdrant request per collection (usually 2: movies + series), instead
  # of one per entry. With ~100 items in history this turns a 100-roundtrip
  # serial fetch into 2 batched lookups — was the source of the ConCache
  # lock contention that hung the home loader at 15s.
  defp map_embeddings(history) do
    history
    |> Enum.reject(&(&1.content_type == "live_channel"))
    |> Enum.group_by(&content_type_to_collection(&1.content_type))
    |> Map.delete(:skip)
    |> Enum.flat_map(fn {collection, entries} ->
      fetch_embeddings_for_collection(collection, entries)
    end)
  end

  defp fetch_embeddings_for_collection(collection, entries) do
    ids = entries |> Enum.map(&embedding_id/1) |> Enum.uniq()

    case qdrant_module().get_points(collection, ids) do
      {:ok, points} ->
        zip_entries_with_vectors(entries, points)

      {:error, reason} ->
        Logger.warning(
          "[UserAnalytics] Qdrant batch fetch failed for #{collection}: #{inspect(reason)}"
        )

        []
    end
  end

  defp zip_entries_with_vectors(entries, points) do
    vectors_by_id = Map.new(points, &{&1.id, &1.vector})

    entries
    |> Enum.map(&entry_to_weighted_vector(&1, vectors_by_id))
    |> Enum.reject(&is_nil/1)
  end

  defp entry_to_weighted_vector(entry, vectors_by_id) do
    case Map.get(vectors_by_id, embedding_id(entry)) do
      nil -> nil
      vector -> %{vector: vector, weight: calculate_weight(entry)}
    end
  end

  defp weighted_profile(content_with_vectors, dimensions, total_weight) do
    Enum.reduce(content_with_vectors, List.duplicate(0.0, dimensions), fn %{
                                                                            vector: vector,
                                                                            weight: weight
                                                                          },
                                                                          acc ->
      apply_weighted_vector(acc, vector, weight, total_weight)
    end)
  end

  defp apply_weighted_vector(acc, vector, weight, total_weight) do
    acc
    |> Enum.zip(vector)
    |> Enum.map(fn {current, value} -> current + value * weight / total_weight end)
  end

  defp qdrant_module do
    Application.get_env(:streamix, :user_profile_qdrant_module, Qdrant)
  end

  defp embedding_id(%{content_type: "episode", series_id: series_id})
       when is_integer(series_id),
       do: series_id

  defp embedding_id(entry), do: entry.content_id

  defp show_adult_content?(user_id) do
    case Accounts.get_user(user_id, preload_role: false) do
      %{show_adult_content: value} -> value
      nil -> false
    end
  end
end
