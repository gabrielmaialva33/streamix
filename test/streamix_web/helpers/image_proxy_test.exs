defmodule StreamixWeb.Helpers.ImageProxyTest do
  use ExUnit.Case, async: false

  alias StreamixWeb.Helpers.ImageProxy

  setup do
    old_proxy = Application.get_env(:streamix, :image_proxy_url)
    Application.put_env(:streamix, :image_proxy_url, "https://img.test")

    on_exit(fn ->
      if old_proxy do
        Application.put_env(:streamix, :image_proxy_url, old_proxy)
      else
        Application.delete_env(:streamix, :image_proxy_url)
      end
    end)
  end

  test "proxies insecure provider poster URLs through the HTTPS image proxy" do
    assert ImageProxy.poster("http://imagecdn.sh/images/poster.jpg", :carousel) ==
             "https://img.test/proxy?url=http%3A%2F%2Fimagecdn.sh%2Fimages%2Fposter.jpg&_v=v2"
  end
end
