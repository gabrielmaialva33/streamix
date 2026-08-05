defmodule Streamix.Billing.PlaybackSessions do
  @moduledoc """
  Tracks active playback slots for plan enforcement.
  """

  import Ecto.Query, warn: false

  alias Streamix.Billing.{Entitlements, PlaybackSession}
  alias Streamix.Repo

  def start_playback_session(%{id: user_id}, attrs)
      when is_integer(user_id) and is_map(attrs) do
    cleanup_stale_playback_sessions!(user_id)

    # Serialize with a Postgres advisory lock keyed on user_id so two
    # concurrent player tabs can't both pass the count check before
    # either insert lands. The transaction is short (count + insert) so
    # the lock is held for milliseconds. Without this, the previous
    # "count -> compare -> insert" was a textbook TOCTOU and let users
    # punch past their plan's :concurrent_streams limit.
    Repo.transaction(fn -> do_start_playback(user_id, attrs) end)
  end

  defp do_start_playback(user_id, attrs) do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [advisory_lock_key(user_id)])

    case ensure_playback_slot_available(user_id) do
      :ok -> do_insert_playback(user_id, attrs)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp do_insert_playback(user_id, attrs) do
    now = DateTime.utc_now(:second)

    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put_new(:session_id, playback_session_id())
      |> Map.put_new(:status, "active")
      |> Map.put_new(:started_at, now)
      |> Map.put(:last_seen_at, now)

    case %PlaybackSession{} |> PlaybackSession.changeset(attrs) |> Repo.insert() do
      {:ok, session} -> session
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Namespace the lock to the playback-sessions context (arbitrary high
  # bits) so it doesn't collide with other advisory locks the app might
  # take elsewhere in the future. Postgres advisory locks live in a
  # single shared namespace.
  defp advisory_lock_key(user_id) do
    Bitwise.bor(Bitwise.bsl(0xB11_BACE, 32), user_id)
  end

  def touch_playback_session(nil), do: :ok

  def touch_playback_session(%PlaybackSession{} = playback_session) do
    playback_session
    |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now(:second))
    |> Repo.update()
    |> case do
      {:ok, _session} ->
        :ok

      {:error, changeset} ->
        # Used to silently return :ok and leave the session looking
        # "active" forever. Logging surfaces the issue without breaking
        # callers that expect :ok.
        require Logger

        Logger.warning("[Billing] touch_playback_session failed: #{inspect(changeset.errors)}")

        {:error, changeset}
    end
  end

  def end_playback_session(nil), do: :ok

  def end_playback_session(%PlaybackSession{id: playback_session_id}) do
    now = DateTime.utc_now(:second)

    from(playback_session in PlaybackSession,
      where: playback_session.id == ^playback_session_id,
      where: playback_session.status != "ended"
    )
    |> Repo.update_all(set: [status: "ended", ended_at: now, last_seen_at: now, updated_at: now])

    :ok
  end

  def active_playback_count(%{id: user_id}) when is_integer(user_id) do
    cleanup_stale_playback_sessions!(user_id)

    active_playback_count_for_user_id(user_id)
  end

  defp active_playback_count_for_user_id(user_id) do
    from(ps in PlaybackSession,
      where: ps.user_id == ^user_id and ps.status == "active"
    )
    |> Repo.aggregate(:count)
  end

  defp ensure_playback_slot_available(user_id) do
    case Entitlements.feature_limit_for_user_id(user_id, :concurrent_streams) do
      nil ->
        :ok

      limit ->
        if active_playback_count_for_user_id(user_id) < limit do
          :ok
        else
          {:error, :concurrent_stream_limit_reached}
        end
    end
  end

  defp cleanup_stale_playback_sessions!(user_id) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -120, :second)
    now = DateTime.utc_now(:second)

    from(ps in PlaybackSession,
      where: ps.user_id == ^user_id,
      where: ps.status == "active",
      where: ps.last_seen_at < ^cutoff
    )
    |> Repo.update_all(set: [status: "ended", ended_at: now, updated_at: now])
  end

  defp playback_session_id do
    "playback:" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end
end
