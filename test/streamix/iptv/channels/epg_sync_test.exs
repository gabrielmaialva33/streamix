defmodule Streamix.Iptv.EpgSyncTest do
  use Streamix.DataCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{EpgProgram, EpgSync}
  alias Streamix.Repo

  describe "cleanup_old_programs/2" do
    setup do
      user = user_fixture()
      provider = provider_fixture(user)
      %{user: user, provider: provider}
    end

    test "deletes programs older than specified hours", %{provider: provider} do
      now = DateTime.utc_now(:second)

      # Create an old program (ended 8 hours ago)
      old_end = DateTime.add(now, -8, :hour)
      old_start = DateTime.add(old_end, -1, :hour)

      _old_program =
        epg_program_fixture(provider, %{
          start_time: old_start,
          end_time: old_end
        })

      # Create a recent program (ends in 30 minutes)
      recent_program =
        epg_program_fixture(provider, %{
          start_time: DateTime.add(now, -30, :minute),
          end_time: DateTime.add(now, 30, :minute)
        })

      assert {:ok, 1} = EpgSync.cleanup_old_programs(provider.id, 6)

      # Only the recent program should remain
      remaining = Repo.all(EpgProgram)
      assert length(remaining) == 1
      assert hd(remaining).id == recent_program.id
    end

    test "returns 0 when no old programs exist", %{provider: provider} do
      now = DateTime.utc_now(:second)

      # Create only recent program
      _recent =
        epg_program_fixture(provider, %{
          start_time: DateTime.add(now, -30, :minute),
          end_time: DateTime.add(now, 30, :minute)
        })

      assert {:ok, 0} = EpgSync.cleanup_old_programs(provider.id, 6)
    end

    test "only deletes programs from specified provider", %{user: user, provider: provider1} do
      provider2 = provider_fixture(user)
      now = DateTime.utc_now(:second)

      old_end = DateTime.add(now, -8, :hour)
      old_start = DateTime.add(old_end, -1, :hour)

      # Old programs for both providers
      _old1 =
        epg_program_fixture(provider1, %{
          start_time: old_start,
          end_time: old_end
        })

      old2 =
        epg_program_fixture(provider2, %{
          start_time: old_start,
          end_time: old_end
        })

      # Cleanup only provider1
      assert {:ok, 1} = EpgSync.cleanup_old_programs(provider1.id, 6)

      # provider2's program should still exist
      remaining = Repo.all(EpgProgram)
      assert length(remaining) == 1
      assert hd(remaining).id == old2.id
    end
  end

  describe "sync_all_epg/1" do
    defmodule Panel do
      @moduledoc false
      import Plug.Conn

      def init(test_pid), do: test_pid

      def call(conn, test_pid) do
        send(test_pid, {:panel_request, conn.request_path})

        xml = """
        <tv>
          <programme channel="sports.br" start="20260503040000 -0300" stop="20260503050000 -0300">
            <title>Jogo ao vivo</title>
          </programme>
        </tv>
        """

        send_resp(conn, 200, xml)
      end
    end

    setup do
      server =
        start_supervised!(
          {Bandit,
           plug: {Panel, self()}, scheme: :http, port: 0, ip: :loopback, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      %{url: "http://127.0.0.1:#{port}"}
    end

    test "never asks for a guide when no channel declares an EPG id", %{url: url} do
      provider = imported!(global_provider_fixture(%{url: url}))
      channel_fixture(provider, %{epg_channel_id: nil})
      channel_fixture(provider, %{epg_channel_id: ""})

      assert {:ok, %{channels: 0, programs: 0}} = EpgSync.sync_all_epg(provider)
      refute_received {:panel_request, _}
      assert %DateTime{} = Repo.reload!(provider).epg_synced_at
    end

    # An empty table before the first import says nothing about the guide,
    # so the next attempt must not wait a whole interval.
    test "waits for the first channel import without stamping", %{url: url} do
      provider = global_provider_fixture(%{url: url})

      assert {:error, :live_catalog_pending} = EpgSync.sync_all_epg(provider)
      refute_received {:panel_request, _}
      assert Repo.reload!(provider).epg_synced_at == nil
    end

    test "fetches the XMLTV once when a channel declares an EPG id", %{url: url} do
      provider = global_provider_fixture(%{url: url})
      channel_fixture(provider, %{epg_channel_id: "sports.br"})

      assert {:ok, %{channels: 1, programs: 1}} = EpgSync.sync_all_epg(provider)
      assert_received {:panel_request, "/xmltv.php"}
      refute_received {:panel_request, _}
      assert [%EpgProgram{title: "Jogo ao vivo"}] = Repo.all(EpgProgram)
    end

    defp imported!(provider) do
      provider
      |> Ecto.Changeset.change(live_synced_at: DateTime.utc_now(:second))
      |> Repo.update!()
    end
  end

  describe "update_epg_synced_at/1" do
    test "sets epg_synced_at to current time" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert provider.epg_synced_at == nil

      {:ok, updated} = EpgSync.update_epg_synced_at(provider)

      assert %DateTime{} = updated.epg_synced_at
      # Should be within last minute
      diff = DateTime.diff(DateTime.utc_now(), updated.epg_synced_at, :second)
      assert diff >= 0 and diff < 60
    end

    test "updates existing epg_synced_at" do
      user = user_fixture()
      provider = provider_fixture(user)

      {:ok, first_update} = EpgSync.update_epg_synced_at(provider)
      first_time = first_update.epg_synced_at

      {:ok, second_update} = EpgSync.update_epg_synced_at(first_update)
      second_time = second_update.epg_synced_at

      # Second update should be equal or later
      assert DateTime.compare(second_time, first_time) in [:eq, :gt]
    end
  end
end
