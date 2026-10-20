defmodule StreamixWeb.CatalogPolishTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias StreamixWeb.App.Media
  alias StreamixWeb.Content.CardComponents
  alias StreamixWeb.Content.NavigationComponents
  alias StreamixWeb.GameComponents

  test "channel status requires a programme covering now" do
    channel = %{id: 42, name: "Canal Teste", stream_icon: nil}
    now = DateTime.utc_now()

    for program <- [
          nil,
          %{title: "Futuro", start_time: DateTime.add(now, 60), end_time: DateTime.add(now, 600)}
        ] do
      html =
        render_component(&Media.live_channel_card/1, channel: channel, current_program: program)

      refute html =~ "AO VIVO"
      assert html =~ "Programação indisponível"
    end

    program = %{
      title: "Agora",
      start_time: DateTime.add(now, -60),
      end_time: DateTime.add(now, 600)
    }

    assert render_component(&Media.live_channel_card/1,
             channel: channel,
             current_program: program
           ) =~ "AO VIVO"
  end

  test "poster fallback has a title and catalog does not repeat source badges" do
    html =
      render_component(&CardComponents.movie_card/1,
        movie: %{id: 42, name: "Filme Teste", provider_id: 1},
        source: "gindex"
      )
      |> Floki.parse_fragment!()

    assert Floki.find(html, "[data-fallback]") |> Floki.text() =~ "Filme Teste"
    refute Floki.text(html) =~ "GDrive"
    assert Floki.find(html, "[data-media-secondary] button[data-size=icon]") != []
  end

  test "catalog and type navigation are named and active type is exposed" do
    html = render_component(&NavigationComponents.source_tabs/1, selected: "gindex")
    assert html =~ "Catálogo:"
    assert html =~ "Google Drive"
    html = render_component(&NavigationComponents.browse_tabs/1, selected: :reels)
    assert html =~ ~s(aria-current="page")
    assert html =~ ~s(aria-label="Tipos do catálogo IPTV")
  end

  test "channel title and favorite use the same readable caption contract" do
    html =
      render_component(&Media.live_channel_card/1,
        channel: %{id: 42, name: "Canal local", stream_icon: nil}
      )
      |> Floki.parse_fragment!()

    assert Floki.find(html, "h3.catalog-poster-title.line-clamp-2") != []
    assert Floki.find(html, "button[data-size=icon][aria-pressed=false]") != []
  end

  test "game crests reserve space and have neutral fallbacks" do
    game = %{
      channel_id: 42,
      title: "Jogo",
      league: "Liga",
      live: false,
      starts_at: DateTime.utc_now(),
      start_time: "16:00",
      home: %{name: "Time Azul", logo_url: nil},
      away: %{name: "Time Branco", logo_url: "/missing.png"}
    }

    html =
      render_component(&GameComponents.rail/1, games: [{"game-42", game}], count: 1)
      |> Floki.parse_fragment!()

    assert Floki.find(html, "[phx-hook=ImageFallback]") |> length() == 2
    assert Floki.find(html, "#game-42-crest-0 [data-fallback]") |> Floki.text() =~ "TA"
    assert Floki.find(html, "#game-42-crest-1 img[data-fallback-target]") != []
    refute Floki.text(html) =~ "AO VIVO"
  end
end
