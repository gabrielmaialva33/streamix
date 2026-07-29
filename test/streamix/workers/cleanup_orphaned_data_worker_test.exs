defmodule Streamix.Workers.CleanupOrphanedDataWorkerTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Iptv.CatalogItem
  alias Streamix.Repo
  alias Streamix.Workers.CleanupOrphanedDataWorker

  test "snoozes after every non-empty batch, then completes on a zero-row proof" do
    provider = global_provider_fixture()
    first = catalog_item_fixture("movie", provider.id)
    second = catalog_item_fixture("movie", provider.id)

    job = %Oban.Job{args: %{"batch_size" => 1}}

    assert {:snooze, 5} = CleanupOrphanedDataWorker.perform(job)
    assert Repo.aggregate(CatalogItem, :count) == 1

    assert {:snooze, 5} = CleanupOrphanedDataWorker.perform(job)
    refute Repo.get(CatalogItem, first.id)
    refute Repo.get(CatalogItem, second.id)

    assert :ok = CleanupOrphanedDataWorker.perform(job)
  end

  test "uses a bounded timeout below the Lifeline threshold" do
    assert CleanupOrphanedDataWorker.timeout(%Oban.Job{}) == :timer.minutes(5)
  end
end
