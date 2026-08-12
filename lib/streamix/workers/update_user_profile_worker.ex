defmodule Streamix.Workers.UpdateUserProfileWorker do
  @moduledoc """
  Background worker for updating user taste profiles.

  Triggered when user finishes watching content. Updates their
  profile vector in Qdrant for personalized recommendations.

  ## Rate Limiting

  Uses Oban's unique constraint to prevent duplicate updates.
  Only one profile update per user runs at a time.
  """

  use Oban.Worker,
    queue: :ai,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:user_id],
      states: :incomplete
    ]

  require Logger

  alias Streamix.AI

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Logger.debug("[UpdateUserProfile] Updating profile for user #{user_id}")

    case AI.compute_user_profile(user_id) do
      {:ok, _vector} ->
        Logger.info("[UpdateUserProfile] Profile updated for user #{user_id}")
        :ok

      {:error, :no_history} ->
        Logger.debug("[UpdateUserProfile] No history for user #{user_id}, skipping")
        :ok

      {:error, :no_embeddings} ->
        Logger.debug("[UpdateUserProfile] No embeddings available for user #{user_id}")
        :ok

      {:error, reason} ->
        Logger.warning("[UpdateUserProfile] Failed for user #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Schedules a profile update for a user.

  Called after watch history is updated. Debounced by Oban's unique constraint.
  Priority based on user activity (more active = higher priority).
  """
  def schedule(user_id, opts \\ []) do
    priority = calculate_priority(user_id, opts)

    %{user_id: user_id}
    |> new(schedule_in: 60, priority: priority)
    |> Oban.insert()
  end

  # Calculate job priority based on user activity
  # Oban: lower number = higher priority (0 = highest, 3 = default)
  defp calculate_priority(_user_id, opts) do
    activity_score = Keyword.get(opts, :activity_score, 0)

    cond do
      # Power users (100+ items watched) - highest priority
      activity_score >= 100 -> 0
      # Active users (50+ items) - high priority
      activity_score >= 50 -> 1
      # Regular users (10+ items) - normal priority
      activity_score >= 10 -> 2
      # New users - default priority
      true -> 3
    end
  end
end
