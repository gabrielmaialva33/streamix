defmodule Streamix.Billing.PlaybackSessions do
  @moduledoc """
  Tracks active playback slots for plan enforcement.
  """

  import Ecto.Query, warn: false

  alias Streamix.Accounts.User
  alias Streamix.Billing.{Entitlements, PlaybackSession}
  alias Streamix.Repo

  def start_playback_session(%User{} = user, attrs) when is_map(attrs) do
    cleanup_stale_playback_sessions!(user.id)

    with :ok <- ensure_playback_slot_available(user) do
      now = DateTime.utc_now(:second)

      attrs =
        attrs
        |> Map.put(:user_id, user.id)
        |> Map.put_new(:session_id, playback_session_id())
        |> Map.put_new(:status, "active")
        |> Map.put_new(:started_at, now)
        |> Map.put(:last_seen_at, now)

      %PlaybackSession{}
      |> PlaybackSession.changeset(attrs)
      |> Repo.insert()
    end
  end

  def touch_playback_session(nil), do: :ok

  def touch_playback_session(%PlaybackSession{} = playback_session) do
    playback_session
    |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now(:second))
    |> Repo.update()
    |> case do
      {:ok, _session} -> :ok
      {:error, _changeset} -> :ok
    end
  end

  def end_playback_session(nil), do: :ok

  def end_playback_session(%PlaybackSession{} = playback_session) do
    now = DateTime.utc_now(:second)

    playback_session
    |> Ecto.Changeset.change(status: "ended", ended_at: now, last_seen_at: now)
    |> Repo.update()
    |> case do
      {:ok, _session} -> :ok
      {:error, _changeset} -> :ok
    end
  end

  def active_playback_count(%User{id: user_id}) do
    cleanup_stale_playback_sessions!(user_id)

    from(ps in PlaybackSession,
      where: ps.user_id == ^user_id and ps.status == "active"
    )
    |> Repo.aggregate(:count)
  end

  defp ensure_playback_slot_available(%User{} = user) do
    case Entitlements.feature_limit_for(user, :concurrent_streams) do
      nil ->
        :ok

      limit ->
        if active_playback_count(user) < limit do
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
