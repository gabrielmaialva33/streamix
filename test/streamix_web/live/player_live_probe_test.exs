defmodule StreamixWeb.PlayerLiveProbeTest do
  @moduledoc """
  A provider that probes each item can take as long as its slowest source to
  name a URL. These tests pin that the player page never waits for it inside
  mount — the LiveView client abandons a join after ten seconds, which is how
  the first try of a title used to show nothing — and that a probe which finds
  nothing usable moves to another provider before the player even exists.
  """
  use StreamixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures

  alias Streamix.Repo

  @panel "93.184.216.34"
  @redirector "104.16.1.1"
  @cdn "104.16.2.2"

  setup :register_and_log_in_user

  setup do
    original = Application.get_env(:streamix, :xtream_delivery, [])
    Application.put_env(:streamix, :xtream_delivery, http_options: [plug: {Req.Test, __MODULE__}])
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Application.put_env(:streamix, :xtream_delivery, original) end)
    :ok
  end

  defp probing_provider(user, name) do
    user
    |> provider_fixture(%{
      name: name,
      visibility: "private",
      provider_type: "xtream",
      is_active: true,
      url: "http://#{@panel}"
    })
    |> Ecto.Changeset.change(direct_client_playback: true)
    |> Repo.update!()
  end

  defp redirect(conn, location) do
    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(302, "")
  end

  # The measured MegaEmbed chain: panel → redirector → a progressive CDN that
  # refuses this server, which the probe hands to the browser instead.
  defp refusing_cdn_chain(%{host: @panel} = conn),
    do: redirect(conn, "https://#{@redirector}/r/abc")

  defp refusing_cdn_chain(%{host: @redirector} = conn),
    do: redirect(conn, "https://#{@cdn}/movies/7/7.mp4?token=tkn-123")

  defp refusing_cdn_chain(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(403, "<title>Attention Required! | Cloudflare</title>")
  end

  test "the page shows the startup screen at once and plays when the source is named", %{
    conn: conn,
    user: user
  } do
    provider = probing_provider(user, "MegaEmbed")
    movie = movie_fixture(provider, %{container_extension: "mp4", stream_id: 9_101})
    Req.Test.stub(__MODULE__, &refusing_cdn_chain/1)

    {:ok, view, html} = live(conn, ~p"/watch/movie/#{movie.id}")

    # Neither render waited for the probe.
    assert html =~ ~s(id="player-startup-screen")
    refute html =~ ~s(id="video-player-container")

    html = render_async(view)

    refute html =~ ~s(id="player-startup-screen")
    assert [stream_url] = view |> render() |> LazyHTML.from_fragment() |> stream_urls()
    assert stream_url =~ "/api/stream/vod/direct.mp4?token="
  end

  test "a probe that finds nothing usable moves to another provider before playing", %{
    conn: conn,
    user: user
  } do
    probing = probing_provider(user, "MegaEmbed")

    plain =
      provider_fixture(user, %{
        name: "Fonte B",
        visibility: "private",
        provider_type: "xtream",
        is_active: true
      })

    gone =
      movie_fixture(probing, %{
        name: "Filme com redundância",
        title: "Filme com redundância",
        year: 2025,
        tmdb_id: "771100",
        stream_id: 9_201
      })

    other =
      movie_fixture(plain, %{
        name: "Filme com redundância",
        title: "Filme com redundância",
        year: 2025,
        tmdb_id: "771100",
        stream_id: 9_202
      })

    # Every source of the probing provider is gone.
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 404, "No playable stream found."))

    {:ok, view, _html} = live(conn, ~p"/watch/movie/#{gone.id}")
    render_async(view)

    document = view |> render() |> LazyHTML.from_fragment()
    assert [stream_url] = stream_urls(document)
    assert stream_url =~ "/api/stream/proxy?token="

    assert document
           |> LazyHTML.query("#video-player-container")
           |> LazyHTML.attribute("data-content-id") == [to_string(other.id)]
  end

  test "a provider that does not probe never shows the startup screen", %{conn: conn, user: user} do
    provider = provider_fixture(user, %{visibility: "private", provider_type: "xtream"})
    movie = movie_fixture(provider, %{container_extension: "mp4"})
    Req.Test.stub(__MODULE__, fn _conn -> flunk("a static route must not probe") end)

    {:ok, _view, html} = live(conn, ~p"/watch/movie/#{movie.id}")

    refute html =~ ~s(id="player-startup-screen")
    assert html =~ ~s(id="video-player-container")
  end

  defp stream_urls(document) do
    document
    |> LazyHTML.query("#video-player-container")
    |> LazyHTML.attribute("data-stream-url")
  end
end
