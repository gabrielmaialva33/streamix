defmodule Streamix.Workers.Gindex.ScanRootWorkerTest do
  use Streamix.DataCase, async: true

  alias Streamix.Workers.Gindex.ScanRootWorker

  test "keeps a root unique across workflow ids while it is active" do
    base_args = %{
      "provider_id" => 42,
      "base_url" => "https://gindex.example/",
      "path" => "/0:/Animes/",
      "kind" => "animes"
    }

    first =
      base_args
      |> Map.put("workflow_id", Ecto.UUID.generate())
      |> ScanRootWorker.new()
      |> Oban.insert!()

    duplicate =
      base_args
      |> Map.put("workflow_id", Ecto.UUID.generate())
      |> ScanRootWorker.new()
      |> Oban.insert!()

    refute first.conflict?
    assert duplicate.conflict?
    assert duplicate.id == first.id
  end
end
