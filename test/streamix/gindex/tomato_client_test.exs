defmodule Streamix.Gindex.TomatoClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Streamix.Gindex.TomatoClient

  setup do
    previous = Application.get_env(:streamix, :tomato)

    Application.put_env(:streamix, :tomato,
      enabled: true,
      bearer_token: "test-token",
      base_url: "http://tomato.test",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    TomatoClient.reset_suspension()

    on_exit(fn ->
      TomatoClient.reset_suspension()

      if previous,
        do: Application.put_env(:streamix, :tomato, previous),
        else: Application.delete_env(:streamix, :tomato)
    end)

    :ok
  end

  test "a banned account pauses the client instead of asking again for every anime" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :tomato_called)

      Req.Test.json(conn, %{"message" => "Banned user.", "status" => false, "status_code" => 12})
    end)

    log =
      capture_log(fn ->
        assert {:error, :banned} = TomatoClient.search_anime("Bleach")
      end)

    assert log =~ "pausing Tomato enrichment"
    assert_received :tomato_called

    refute TomatoClient.enabled?()
    assert {:error, :tomato_not_configured} = TomatoClient.search_anime("Naruto")
    refute_received :tomato_called
  end

  test "any other refusal is reported without pausing" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"message" => "Bad query.", "status" => false, "status_code" => 3})
    end)

    capture_log(fn ->
      assert {:error, :not_ok} = TomatoClient.search_anime("Bleach")
    end)

    assert TomatoClient.enabled?()
  end

  test "results are normalized" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "status" => true,
        "result" => [%{"id" => 7, "name" => "Bleach", "tags" => "DUBLADO", "date" => 2004}]
      })
    end)

    assert {:ok, [%{tomato_id: 7, name: "Bleach", dubbed: true, year: 2004}]} =
             TomatoClient.search_anime("Bleach")
  end
end
