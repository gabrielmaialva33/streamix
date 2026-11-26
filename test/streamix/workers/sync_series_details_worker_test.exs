defmodule Streamix.Workers.SyncSeriesDetailsWorkerTest do
  use Streamix.DataCase, async: false
  use Oban.Testing, repo: Streamix.Repo

  import Streamix.IptvFixtures

  alias Streamix.Iptv.Streaming.ProviderRuntime
  alias Streamix.Iptv.XtreamCircuitBreaker
  alias Streamix.Workers.SyncSeriesDetailsWorker

  setup do
    req = Req.default_options()
    timeout = Application.get_env(:streamix, :series_details_timeout_ms)
    Req.default_options(plug: {Req.Test, __MODULE__}, retry: false)
    Application.put_env(:streamix, :series_details_timeout_ms, 500)
    ProviderRuntime.reset()
    XtreamCircuitBreaker.reset_all()

    on_exit(fn ->
      Req.default_options(req)

      if timeout,
        do: Application.put_env(:streamix, :series_details_timeout_ms, timeout),
        else: Application.delete_env(:streamix, :series_details_timeout_ms)

      ProviderRuntime.reset()
      XtreamCircuitBreaker.reset_all()
    end)

    provider = global_provider_fixture(%{url: "http://127.0.0.1:1"})
    %{series: series_content_fixture(provider)}
  end

  @tag timeout: 60_000
  test "a timed out series keeps the batch failed", %{series: series} do
    Req.Test.stub(__MODULE__, fn _conn ->
      receive do
        :never_sent -> raise "unreachable"
      end
    end)

    assert {:error, {:series_sync_failed, 1}} =
             SyncSeriesDetailsWorker.perform(%Oban.Job{
               args: %{"series_ids" => [series.id]},
               attempt: 1
             })
  end

  test "partial failure stays on the same job instead of losing a retry insertion", %{
    series: series
  } do
    successful =
      global_provider_fixture(%{provider_type: :gindex})
      |> series_content_fixture()

    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 403, "denied"))

    assert {:error, {:series_sync_failed, 1}} =
             SyncSeriesDetailsWorker.perform(%Oban.Job{
               args: %{"series_ids" => [series.id, successful.id]},
               attempt: 1
             })

    refute_enqueued(worker: SyncSeriesDetailsWorker)
  end

  test "permanent failure exhausts five attempts without creating successor jobs", %{
    series: series
  } do
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 403, "denied"))
    job = %{series_ids: [series.id]} |> SyncSeriesDetailsWorker.new() |> Oban.insert!()

    for attempt <- 1..5 do
      result = Oban.drain_queue(queue: :series_details, with_scheduled: true)
      assert result.snoozed == 0
      assert result.failure == if(attempt == 5, do: 0, else: 1)
      assert result.discard == if(attempt == 5, do: 1, else: 0)

      current = Repo.get!(Oban.Job, job.id)
      assert current.attempt == attempt
      assert current.state == if(attempt == 5, do: "discarded", else: "retryable")
    end

    assert Repo.aggregate(Oban.Job, :count) == 1
  end
end
