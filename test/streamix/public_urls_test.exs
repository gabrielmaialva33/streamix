defmodule Streamix.PublicUrlsTest do
  use ExUnit.Case, async: false

  alias Streamix.PublicUrls

  setup do
    previous = Application.get_env(:streamix, :stream_proxy_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:streamix, :stream_proxy_url, previous),
        else: Application.delete_env(:streamix, :stream_proxy_url)
    end)
  end

  test "an origin set in config wins" do
    Application.put_env(:streamix, :stream_proxy_url, "https://edge.example")
    assert PublicUrls.stream_proxy() == "https://edge.example"
  end

  test "an unset origin falls back to the production edge" do
    Application.delete_env(:streamix, :stream_proxy_url)
    assert PublicUrls.stream_proxy() == "https://source.mahina.fun"
  end
end
