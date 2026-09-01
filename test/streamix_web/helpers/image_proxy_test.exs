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

  test "does not proxy private network image URLs" do
    assert ImageProxy.poster("http://127.0.0.1/admin.jpg", :carousel) == nil
    assert ImageProxy.poster("http://10.8.0.1/admin.jpg", :carousel) == nil
    assert ImageProxy.poster("http://localhost/admin.jpg", :carousel) == nil
    assert ImageProxy.poster("http://2130706433/admin.jpg", :carousel) == nil
    assert ImageProxy.poster("http://0x7f000001/admin.jpg", :carousel) == nil
  end

  test "omits poster hosts proven unusable in browsers" do
    assert ImageProxy.browser_poster(
             "https://png.pngtree.com/thumb_back/fw800/background/20230616/pngtree.jpg",
             :carousel
           ) == nil

    assert ImageProxy.browser_poster(
             "https://static.vecteezy.com/system/resources/previews/001/poster.png",
             :hero
           ) == nil
  end

  test "omits blocked raw images while keeping normal browser images proxied" do
    assert ImageProxy.browser_image("https://png.pngtree.com/png-vector/blocked-image.png") == nil

    assert ImageProxy.browser_image("https://example.com/icon.png") ==
             "https://example.com/icon.png?_v=v2"
  end

  test "keeps normal browser posters on the existing proxy path" do
    assert ImageProxy.browser_poster("https://example.com/poster.jpg", :carousel) ==
             "https://example.com/poster.jpg?_v=v2"
  end

  test "builds a responsive TMDB hero source set" do
    srcset =
      ImageProxy.srcset("https://tmdb.mahina.fun/t/p/w1280/backdrop.jpg?_v=v2", :hero)

    assert srcset =~ "/w500/backdrop.jpg 500w"
    assert srcset =~ "/w780/backdrop.jpg 780w"
    assert srcset =~ "/w1280/backdrop.jpg 1280w"
    refute srcset =~ "/w185/"
  end
end
