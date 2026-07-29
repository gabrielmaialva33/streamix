defmodule Streamix.Torrent.Sources.HelpersTest do
  use ExUnit.Case, async: false

  alias Streamix.Torrent.Sources.Helpers

  setup do
    previous = Application.get_env(:streamix, :torrent_source_endpoints)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:streamix, :torrent_source_endpoints)
      else
        Application.put_env(:streamix, :torrent_source_endpoints, previous)
      end
    end)

    :ok
  end

  test "reads the runtime keyword-list configuration" do
    Application.put_env(:streamix, :torrent_source_endpoints,
      eztv: "https://feeds.example/eztv",
      gratistorrent: nil,
      comandotorrent: nil
    )

    assert Helpers.configured_endpoint("eztv") == {:ok, "https://feeds.example/eztv"}
    assert Helpers.configured_endpoint("gratistorrent") == {:error, :not_configured}
  end

  test "keeps supporting map overrides" do
    Application.put_env(:streamix, :torrent_source_endpoints, %{
      "comandotorrent" => "https://feeds.example/comando"
    })

    assert Helpers.configured_endpoint("comandotorrent") ==
             {:ok, "https://feeds.example/comando"}
  end
end
