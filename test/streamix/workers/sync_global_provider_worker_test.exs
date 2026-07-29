defmodule Streamix.Workers.SyncGlobalProviderWorkerTest do
  use Streamix.DataCase, async: false
  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.Iptv.GlobalProvider
  alias Streamix.Workers.{SyncGlobalProviderWorker, SyncProviderWorker}

  setup do
    prior = Application.get_env(:streamix, :global_provider)

    Application.put_env(:streamix, :global_provider,
      enabled: true,
      name: "Global Worker Test",
      url: "https://global-worker.example.com",
      username: "test-user",
      password: "test-password"
    )

    on_exit(fn ->
      if prior do
        Application.put_env(:streamix, :global_provider, prior)
      else
        Application.delete_env(:streamix, :global_provider)
      end
    end)

    :ok
  end

  test "delegates the global provider to the provider-scoped sync worker" do
    assert :ok = SyncGlobalProviderWorker.perform(%Oban.Job{})

    provider = GlobalProvider.get()

    assert_enqueued(
      worker: SyncProviderWorker,
      args: %{provider_id: provider.id, series_details: "skip"}
    )
  end
end
