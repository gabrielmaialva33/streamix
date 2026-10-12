defmodule Streamix.Iptv.Streaming.XtreamHls.SessionsTest do
  use ExUnit.Case, async: false

  alias Streamix.Iptv.Streaming.XtreamHls.Sessions

  @url "http://93.184.216.34/movie/u/p/1.m3u8"

  setup do
    original = Application.get_env(:streamix, :xtream_hls, [])
    Application.put_env(:streamix, :xtream_hls, max_fetches_per_provider: 1, lease_wait_ms: 2_000)
    on_exit(fn -> Application.put_env(:streamix, :xtream_hls, original) end)

    %{provider_id: System.unique_integer([:positive])}
  end

  describe "leases" do
    test "a released slot goes to the oldest waiter", %{provider_id: provider_id} do
      {:ok, held} = Sessions.acquire(provider_id)
      owner = self()

      waiter =
        Task.async(fn ->
          send(owner, :waiting)
          Sessions.acquire(provider_id)
        end)

      assert_receive :waiting
      # The waiter is queued, not refused.
      refute Task.yield(waiter, 50)

      Sessions.release(held)
      assert {:ok, lease} = Task.await(waiter)
      assert is_reference(lease)
    end

    test "a slot held by a process that dies is reclaimed", %{provider_id: provider_id} do
      holder =
        Task.async(fn ->
          {:ok, _lease} = Sessions.acquire(provider_id)
          :held
        end)

      assert Task.await(holder) == :held
      assert {:ok, lease} = Sessions.acquire(provider_id)
      Sessions.release(lease)
    end

    test "providers do not share slots", %{provider_id: provider_id} do
      {:ok, first} = Sessions.acquire(provider_id)
      {:ok, other} = Sessions.acquire(provider_id + 1)

      Enum.each([first, other], &Sessions.release/1)
    end

    test "a waiter past the deadline is refused", %{provider_id: provider_id} do
      Application.put_env(:streamix, :xtream_hls, max_fetches_per_provider: 1, lease_wait_ms: 10)
      {:ok, held} = Sessions.acquire(provider_id)

      assert {:error, :provider_capacity_exhausted} = Sessions.acquire(provider_id)
      Sessions.release(held)
    end
  end

  describe "sessions" do
    test "an item reuses its session while the source URL is unchanged" do
      content = {:movie, System.unique_integer([:positive])}

      assert {:ok, first} = Sessions.open(content, 1, @url)
      assert {:ok, ^first} = Sessions.open(content, 1, @url)

      # Changed credentials mean a different root URL, so a new graph.
      assert {:ok, second} = Sessions.open(content, 1, @url <> "?source=2")
      refute second.session_id == first.session_id

      assert {:error, :resource_not_found} =
               Sessions.resource(second.session_id, second.resource_id, {:episode, 1})

      assert {:ok, %{url: @url <> "?source=2", kind: :playlist}, %{provider_id: 1, template: nil}} =
               Sessions.resource(second.session_id, second.resource_id, content)
    end

    test "a live session is shared while alive and goes after the live idle time" do
      content = {:channel, System.unique_integer([:positive])}
      live_url = "http://93.184.216.34/live/u/p/501.ts"
      {:ok, session} = Sessions.open(content, 1, live_url)

      age = fn field, seconds ->
        :sys.replace_state(Sessions, fn state ->
          put_in(
            state.sessions[session.session_id][field],
            System.monotonic_time(:second) - seconds
          )
        end)
      end

      # Older than the VOD reuse TTL, but alive: every viewer shares it.
      age.(:created_at, 3_600)
      assert {:ok, ^session} = Sessions.open(content, 1, live_url)

      assert {:ok, %{kind: :playlist}, %{live?: true, root: root}} =
               Sessions.resource(session.session_id, session.resource_id, content)

      assert root == session.resource_id

      # Five idle minutes end it (VOD sessions get thirty).
      age.(:touched_at, 301)

      assert {:error, :playback_restart_required} =
               Sessions.resource(session.session_id, session.resource_id, content)
    end

    test "an idle session asks the player to restart, then is gone" do
      content = {:episode, System.unique_integer([:positive])}
      {:ok, session} = Sessions.open(content, 1, @url)

      :sys.replace_state(Sessions, fn state ->
        put_in(
          state.sessions[session.session_id].touched_at,
          System.monotonic_time(:second) - 1801
        )
      end)

      assert {:error, :playback_restart_required} =
               Sessions.resource(session.session_id, session.resource_id, content)

      assert {:error, :resource_not_found} =
               Sessions.resource(session.session_id, session.resource_id, content)
    end
  end
end
