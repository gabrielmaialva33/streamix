defmodule Streamix.Workers.SyncProviderWorkerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv
  alias Streamix.Workers.SyncProviderWorker

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  describe "enqueue/1 with Provider struct" do
    test "enqueues a job with provider_id" do
      user = user_fixture()
      provider = provider_fixture(user)

      assert {:ok, %Oban.Job{} = job} = SyncProviderWorker.enqueue(provider)
      assert job.args == %{"provider_id" => provider.id}
      assert job.queue == "sync"
    end

    test "job has correct configuration" do
      user = user_fixture()
      provider = provider_fixture(user)

      {:ok, job} = SyncProviderWorker.enqueue(provider)

      # In inline mode, job is executed immediately, so we just verify the struct
      assert job.worker == "Streamix.Workers.SyncProviderWorker"
      assert job.max_attempts == 3
    end
  end

  describe "enqueue/1 with provider_id" do
    test "enqueues a job with integer provider_id" do
      assert {:ok, %Oban.Job{} = job} = SyncProviderWorker.enqueue(123)
      assert job.args == %{"provider_id" => 123}
    end

    test "enqueues a job with string provider_id" do
      assert {:ok, %Oban.Job{} = job} = SyncProviderWorker.enqueue("456")
      assert job.args == %{"provider_id" => "456"}
    end
  end

  describe "perform/1" do
    test "returns error when provider not found" do
      job = %Oban.Job{args: %{"provider_id" => 0}}

      assert {:error, :provider_not_found} = SyncProviderWorker.perform(job)
    end

    test "updates provider sync_status to syncing before sync" do
      user = user_fixture()
      provider = provider_fixture(user)

      # Subscribe to PubSub to verify broadcast
      Phoenix.PubSub.subscribe(Streamix.PubSub, "provider:#{provider.id}")

      job = %Oban.Job{args: %{"provider_id" => provider.id}}

      # This will fail because we don't have a real IPTV server
      # but it should still update status to syncing first
      SyncProviderWorker.perform(job)

      # Verify status was updated (even if sync failed)
      updated = Iptv.get_provider!(provider.id)
      assert updated.sync_status in ["syncing", "failed"]
    end

    test "broadcasts sync status updates" do
      user = user_fixture()
      provider = provider_fixture(user)

      # Subscribe to both topics
      Phoenix.PubSub.subscribe(Streamix.PubSub, "provider:#{provider.id}")
      Phoenix.PubSub.subscribe(Streamix.PubSub, "user:#{user.id}:providers")

      job = %Oban.Job{args: %{"provider_id" => provider.id}}
      SyncProviderWorker.perform(job)

      # Should receive at least the "syncing" status
      assert_receive {:sync_status, %{status: "syncing", provider_id: provider_id}}
      assert provider_id == provider.id
    end

    test "sets status to failed when sync fails" do
      user = user_fixture()
      provider = provider_fixture(user)

      job = %Oban.Job{args: %{"provider_id" => provider.id}}

      # Will fail because we can't connect to the fake provider URL
      SyncProviderWorker.perform(job)

      updated = Iptv.get_provider!(provider.id)
      assert updated.sync_status == "failed"
    end
  end

  describe "job configuration" do
    test "uses sync queue" do
      user = user_fixture()
      provider = provider_fixture(user)

      {:ok, job} = SyncProviderWorker.enqueue(provider)

      assert job.queue == "sync"
    end

    test "has max_attempts of 3" do
      user = user_fixture()
      provider = provider_fixture(user)

      {:ok, job} = SyncProviderWorker.enqueue(provider)

      assert job.max_attempts == 3
    end
  end
end
