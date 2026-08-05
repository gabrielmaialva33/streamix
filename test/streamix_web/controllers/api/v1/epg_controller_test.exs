defmodule StreamixWeb.Api.V1.EpgControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Iptv.{EpgChannel, EpgProgram}
  alias Streamix.Repo

  setup do
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, [])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)

    provider = global_provider_fixture()
    {:ok, provider: provider}
  end

  # Wires up: LiveChannel -> EpgChannel (by external_id) -> EpgProgram.
  # Returns {live_channel, current_program}.
  defp seed_channel_with_program(provider, external_id, opts \\ []) do
    now = DateTime.utc_now(:second)
    start_time = Keyword.get(opts, :start, DateTime.add(now, -30, :minute))
    end_time = Keyword.get(opts, :end, DateTime.add(now, 30, :minute))
    title = Keyword.get(opts, :title, "Now Playing")

    live =
      channel_fixture(provider, %{
        epg_channel_id: external_id,
        name: "LC #{external_id}"
      })

    epg_channel =
      %EpgChannel{}
      |> EpgChannel.changeset(%{
        external_id: external_id,
        provider_id: provider.id,
        name: external_id
      })
      |> Repo.insert!()

    program =
      %EpgProgram{}
      |> EpgProgram.changeset(%{
        epg_channel_id: epg_channel.id,
        title: title,
        description: "Test description",
        category: "Test",
        start_time: start_time,
        end_time: end_time
      })
      |> Repo.insert!()

    {live, program}
  end

  describe "GET /api/v1/epg/now" do
    test "returns program for a channel with EPG data", %{conn: conn, provider: provider} do
      {live, _program} = seed_channel_with_program(provider, "ch.one")

      response =
        conn
        |> get("/api/v1/epg/now?channel_ids=#{live.id}")
        |> json_response(200)

      assert %{"now" => now_map} = response
      assert Map.has_key?(now_map, to_string(live.id))

      entry = Map.fetch!(now_map, to_string(live.id))
      assert entry["title"] == "Now Playing"
      assert entry["description"] == "Test description"
      assert is_binary(entry["start"])
      assert is_binary(entry["end"])
      # progress is a float in [0.0, 1.0]
      progress = entry["progress"]
      assert is_float(progress)
      assert progress >= 0.0 and progress <= 1.0
    end

    test "returns null for channels without EPG data", %{conn: conn, provider: provider} do
      {live_with, _} = seed_channel_with_program(provider, "ch.has-epg")

      live_without =
        channel_fixture(provider, %{
          epg_channel_id: "ch.no-epg",
          name: "Empty"
        })

      response =
        conn
        |> get("/api/v1/epg/now?channel_ids=#{live_with.id},#{live_without.id}")
        |> json_response(200)

      now_map = response["now"]

      assert Map.fetch!(now_map, to_string(live_with.id))["title"] == "Now Playing"
      assert Map.fetch!(now_map, to_string(live_without.id)) == nil
    end

    test "400 when channel_ids missing", %{conn: conn} do
      response = conn |> get("/api/v1/epg/now") |> json_response(400)
      assert response["error"]["code"] == "missing_params"
    end

    test "ignores non-integer channel_ids", %{conn: conn, provider: provider} do
      {live, _} = seed_channel_with_program(provider, "ch.valid")

      response =
        conn
        |> get("/api/v1/epg/now?channel_ids=#{live.id},garbage,abc")
        |> json_response(200)

      # Only the valid id gets a keyed entry.
      assert Map.keys(response["now"]) == [to_string(live.id)]
    end

    test "does not accept a valid integer prefix", %{conn: conn, provider: provider} do
      {live, _} = seed_channel_with_program(provider, "ch.partial")

      response =
        conn
        |> get("/api/v1/epg/now?channel_ids=#{live.id}junk")
        |> json_response(200)

      assert response == %{"now" => %{}}
    end

    test "caps the number of channel ids accepted per request", %{conn: conn} do
      ids = Enum.map_join(1..150, ",", &Integer.to_string/1)
      response = conn |> get("/api/v1/epg/now?channel_ids=#{ids}") |> json_response(200)

      assert map_size(response["now"]) == 100
    end
  end

  describe "GET /api/v1/epg/programs" do
    test "returns programs grouped by channel_id", %{conn: conn, provider: provider} do
      now = DateTime.utc_now(:second)

      {live, _now_prog} =
        seed_channel_with_program(provider, "ch.sched",
          start: DateTime.add(now, -30, :minute),
          end: DateTime.add(now, 30, :minute),
          title: "Current"
        )

      # Add a future program on the same EPG channel.
      epg_channel = Repo.get_by!(EpgChannel, external_id: "ch.sched", provider_id: provider.id)

      %EpgProgram{}
      |> EpgProgram.changeset(%{
        epg_channel_id: epg_channel.id,
        title: "Next",
        start_time: DateTime.add(now, 30, :minute),
        end_time: DateTime.add(now, 90, :minute)
      })
      |> Repo.insert!()

      response =
        conn
        |> get("/api/v1/epg/programs?channel_ids=#{live.id}&hours=3")
        |> json_response(200)

      progs = response["programs"][to_string(live.id)]
      assert is_list(progs)
      assert length(progs) == 2
      titles = Enum.map(progs, & &1["title"])
      assert "Current" in titles
      assert "Next" in titles

      # Shape check on a single entry.
      [first | _] = progs
      assert Map.has_key?(first, "title")
      assert Map.has_key?(first, "description")
      assert Map.has_key?(first, "start")
      assert Map.has_key?(first, "end")
    end

    test "returns empty list for channels without EPG", %{conn: conn, provider: provider} do
      live =
        channel_fixture(provider, %{
          epg_channel_id: "ch.none",
          name: "Empty Channel"
        })

      response =
        conn
        |> get("/api/v1/epg/programs?channel_ids=#{live.id}")
        |> json_response(200)

      assert response["programs"][to_string(live.id)] == []
    end
  end
end
