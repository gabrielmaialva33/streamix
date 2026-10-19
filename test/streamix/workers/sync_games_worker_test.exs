defmodule Streamix.Workers.SyncGamesWorkerTest do
  use Streamix.DataCase, async: false
  use Oban.Testing, repo: Streamix.Repo
  import Streamix.IptvFixtures
  import Streamix.GamesFixtures
  alias Streamix.Workers.SyncGamesWorker

  test "cron dispatches only enabled active Xtream providers, deduplicates and prunes" do
    enabled = global_provider_fixture(%{games_enabled: true})
    disabled = global_provider_fixture()

    inactive =
      global_provider_fixture(%{games_enabled: true})
      |> Ecto.Changeset.change(is_active: false)
      |> Repo.update!()

    torrent = global_provider_fixture(%{games_enabled: true, provider_type: :torrent})
    now = DateTime.utc_now(:second)

    old =
      game_fixture(enabled, nil, %{
        starts_at: DateTime.add(now, -60_000),
        ends_at: DateTime.add(now, -50_000)
      })

    assert :ok = SyncGamesWorker.perform(%Oban.Job{})
    assert :ok = SyncGamesWorker.perform(%Oban.Job{})
    assert [%{args: %{"provider_id" => id}}] = all_enqueued(worker: SyncGamesWorker)
    assert id == enabled.id

    for provider <- [disabled, inactive, torrent] do
      refute_enqueued(worker: SyncGamesWorker, args: %{provider_id: provider.id})
    end

    refute Repo.get(Streamix.Iptv.SportsMatch, old.id)
  end

  test "queued jobs recheck opt-in and sync only safe data" do
    provider =
      global_provider_fixture(%{
        games_enabled: true,
        send_x_domain: true,
        url: "https://93.184.216.34"
      })

    channel = channel_fixture(provider)
    now = DateTime.utc_now(:second)
    previous = Application.get_env(:streamix, :games_http_options, [])
    Application.put_env(:streamix, :games_http_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.put_env(:streamix, :games_http_options, previous) end)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, [
        game_payload(provider, channel.stream_id, now, DateTime.add(now, 3600))
      ])
    end)

    assert :ok = perform_job(SyncGamesWorker, %{provider_id: provider.id})
    assert [_] = Streamix.Catalog.list_games(nil)
    provider |> Ecto.Changeset.change(games_enabled: false) |> Repo.update!()
    Req.Test.stub(__MODULE__, fn _conn -> flunk("disabled feed requested") end)
    assert :ok = perform_job(SyncGamesWorker, %{provider_id: provider.id})
  end
end
