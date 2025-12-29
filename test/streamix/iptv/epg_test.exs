defmodule Streamix.Iptv.EpgTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.Epg

  describe "get_now_and_next/2" do
    setup do
      user = user_fixture()
      provider = provider_fixture(user)
      %{provider: provider}
    end

    test "returns current and next program", %{provider: provider} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      epg_channel_id = "test_channel"

      # Current program (started 30 min ago, ends in 30 min)
      current =
        epg_program_fixture(provider, %{
          epg_channel_id: epg_channel_id,
          title: "Current Show",
          start_time: DateTime.add(now, -30, :minute),
          end_time: DateTime.add(now, 30, :minute)
        })

      # Next program (starts in 30 min)
      next =
        epg_program_fixture(provider, %{
          epg_channel_id: epg_channel_id,
          title: "Next Show",
          start_time: DateTime.add(now, 30, :minute),
          end_time: DateTime.add(now, 90, :minute)
        })

      result = Epg.get_now_and_next(provider.id, epg_channel_id)

      assert result.current.id == current.id
      assert result.current.title == "Current Show"
      assert result.next.id == next.id
      assert result.next.title == "Next Show"
    end

    test "returns nil when no programs exist", %{provider: provider} do
      result = Epg.get_now_and_next(provider.id, "nonexistent_channel")

      assert result.current == nil
      assert result.next == nil
    end

    test "returns nil for nil epg_channel_id", %{provider: provider} do
      result = Epg.get_now_and_next(provider.id, nil)

      assert result.current == nil
      assert result.next == nil
    end

    test "handles program that already ended", %{provider: provider} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      epg_channel_id = "test_channel"

      # Past program (ended 1 hour ago)
      _past =
        epg_program_fixture(provider, %{
          epg_channel_id: epg_channel_id,
          title: "Past Show",
          start_time: DateTime.add(now, -2, :hour),
          end_time: DateTime.add(now, -1, :hour)
        })

      # Future program
      future =
        epg_program_fixture(provider, %{
          epg_channel_id: epg_channel_id,
          title: "Future Show",
          start_time: DateTime.add(now, 1, :hour),
          end_time: DateTime.add(now, 2, :hour)
        })

      result = Epg.get_now_and_next(provider.id, epg_channel_id)

      assert result.current == nil
      assert result.next.id == future.id
    end
  end

  describe "get_current_programs_batch/2" do
    setup do
      user = user_fixture()
      provider = provider_fixture(user)
      %{provider: provider}
    end

    test "returns current programs for multiple channels", %{provider: provider} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Create programs for 3 channels
      prog1 =
        epg_program_fixture(provider, %{
          epg_channel_id: "ch1",
          title: "Program 1",
          start_time: DateTime.add(now, -30, :minute),
          end_time: DateTime.add(now, 30, :minute)
        })

      prog2 =
        epg_program_fixture(provider, %{
          epg_channel_id: "ch2",
          title: "Program 2",
          start_time: DateTime.add(now, -10, :minute),
          end_time: DateTime.add(now, 50, :minute)
        })

      # ch3 has no current program (ended)
      _past =
        epg_program_fixture(provider, %{
          epg_channel_id: "ch3",
          title: "Past Program",
          start_time: DateTime.add(now, -2, :hour),
          end_time: DateTime.add(now, -1, :hour)
        })

      result = Epg.get_current_programs_batch(provider.id, ["ch1", "ch2", "ch3", "ch4"])

      assert map_size(result) == 2
      assert result["ch1"].id == prog1.id
      assert result["ch2"].id == prog2.id
      assert result["ch3"] == nil
      assert result["ch4"] == nil
    end

    test "returns empty map for empty channel list", %{provider: provider} do
      result = Epg.get_current_programs_batch(provider.id, [])
      assert result == %{}
    end

    test "filters out nil channel ids", %{provider: provider} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      prog =
        epg_program_fixture(provider, %{
          epg_channel_id: "ch1",
          start_time: DateTime.add(now, -30, :minute),
          end_time: DateTime.add(now, 30, :minute)
        })

      result = Epg.get_current_programs_batch(provider.id, [nil, "ch1", nil])

      assert map_size(result) == 1
      assert result["ch1"].id == prog.id
    end
  end

  describe "enrich_channels_with_epg/2" do
    setup do
      user = user_fixture()
      provider = provider_fixture(user)
      %{provider: provider}
    end

    test "adds current_program to channels", %{provider: provider} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      channel1 = channel_fixture(provider, %{epg_channel_id: "epg1"})
      channel2 = channel_fixture(provider, %{epg_channel_id: "epg2"})

      prog1 =
        epg_program_fixture(provider, %{
          epg_channel_id: "epg1",
          title: "Show on Channel 1",
          start_time: DateTime.add(now, -30, :minute),
          end_time: DateTime.add(now, 30, :minute)
        })

      channels = [channel1, channel2]
      enriched = Epg.enrich_channels_with_epg(channels, provider.id)

      assert length(enriched) == 2

      [ch1, ch2] = enriched
      assert ch1.current_program.id == prog1.id
      assert ch2.current_program == nil
    end

    test "handles empty channel list", %{provider: provider} do
      result = Epg.enrich_channels_with_epg([], provider.id)
      assert result == []
    end
  end
end
