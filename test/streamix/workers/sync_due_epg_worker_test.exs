defmodule Streamix.Workers.SyncDueEpgWorkerTest do
  use Streamix.DataCase, async: false

  use Oban.Testing, repo: Streamix.Repo

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Repo
  alias Streamix.Workers.{SyncDueEpgWorker, SyncEpgWorker}

  defp synced(provider, hours_ago) do
    at = DateTime.add(DateTime.utc_now(:second), -hours_ago * 3600)
    provider |> Ecto.Changeset.change(epg_synced_at: at) |> Repo.update!()
  end

  test "every active provider with a stale guide is refreshed, not only the global one" do
    user = user_fixture()
    global = global_provider_fixture() |> synced(1)
    stale = provider_fixture(user, %{provider_type: "xtream", is_active: true}) |> synced(30)
    never = provider_fixture(user, %{provider_type: "xtream", is_active: true})
    inactive = provider_fixture(user, %{provider_type: "xtream", is_active: false}) |> synced(30)

    assert :ok = perform_job(SyncDueEpgWorker, %{})

    assert_enqueued worker: SyncEpgWorker, args: %{"provider_id" => stale.id}
    assert_enqueued worker: SyncEpgWorker, args: %{"provider_id" => never.id}
    refute_enqueued worker: SyncEpgWorker, args: %{"provider_id" => global.id}
    refute_enqueued worker: SyncEpgWorker, args: %{"provider_id" => inactive.id}
  end
end
