defmodule Streamix.Iptv.EpgSyncTest do
  use Streamix.DataCase, async: true

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
      now = DateTime.utc_now() |> DateTime.truncate(:second)

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
      now = DateTime.utc_now() |> DateTime.truncate(:second)

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
      now = DateTime.utc_now() |> DateTime.truncate(:second)

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

      # Wait a tiny bit to ensure different timestamp
      Process.sleep(10)

      {:ok, second_update} = EpgSync.update_epg_synced_at(first_update)
      second_time = second_update.epg_synced_at

      # Second update should be equal or later
      assert DateTime.compare(second_time, first_time) in [:eq, :gt]
    end
  end
end
