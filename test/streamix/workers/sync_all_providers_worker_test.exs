defmodule Streamix.Workers.SyncAllProvidersWorkerTest do
  use Streamix.DataCase, async: true
  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.Workers.{SyncAllProvidersWorker, SyncProviderWorker}

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  test "enqueues personal Xtream providers but leaves the global provider to its worker" do
    user = user_fixture()
    personal_provider = provider_fixture(user)
    global_provider = global_provider_fixture()

    assert :ok = SyncAllProvidersWorker.perform(%Oban.Job{})

    assert_enqueued(
      worker: SyncProviderWorker,
      args: %{provider_id: personal_provider.id, series_details: "skip"}
    )

    refute_enqueued(
      worker: SyncProviderWorker,
      args: %{provider_id: global_provider.id}
    )
  end
end
