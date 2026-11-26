defmodule StreamixWeb.Catalog.ImageProxyTest do
  use ExUnit.Case, async: false

  alias StreamixWeb.Catalog.ImageProxy

  setup do
    previous = Application.get_env(:streamix, :tmdb_proxy_url)
    Application.put_env(:streamix, :tmdb_proxy_url, "https://poster.example")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:streamix, :tmdb_proxy_url, previous),
        else: Application.delete_env(:streamix, :tmdb_proxy_url)
    end)
  end

  test "normalizes legacy TMDB URLs before adding the catalog cache version" do
    for source <- [
          "http://image.tmdb.org//t/p/w500/poster.jpg",
          "https://image.tmdb.org/t/p/w500/poster.jpg"
        ] do
      assert ImageProxy.proxy(source) == "https://poster.example/t/p/w500/poster.jpg?_v=v2"
    end
  end

  test "preserves list shape and empty images without exposing private image targets" do
    assert ImageProxy.proxy([nil, "", "http://127.0.0.1/private.jpg"]) == [nil, nil, nil]
  end
end
