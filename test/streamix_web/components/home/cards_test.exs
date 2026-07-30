defmodule StreamixWeb.Home.CardsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.Content.CarouselComponents, as: ContentCarousel
  alias StreamixWeb.Home.{Cards, Carousel, Landing}

  @blocked_image "https://png.pngtree.com/png-vector/blocked-image.png"

  test "history cards select their fallback before blocked images reach the browser" do
    html =
      render_component(&Cards.history_item/1,
        entry: %{
          id: 1,
          content_type: "live_channel",
          content_id: 10,
          content_icon: @blocked_image,
          content_name: "Canal",
          progress_seconds: nil,
          duration_seconds: nil,
          watched_at: DateTime.utc_now()
        }
      )

    refute html =~ "png.pngtree.com"
    refute html =~ "<img"
    assert html =~ "data-fallback"
  end

  test "favorite cards select their fallback before blocked images reach the browser" do
    html =
      render_component(&Cards.favorite_item/1,
        favorite: %{
          content_type: "movie",
          content_id: 20,
          content_icon: @blocked_image,
          content_name: "Filme"
        }
      )

    refute html =~ "png.pngtree.com"
    refute html =~ "<img"
    assert html =~ "data-fallback"
  end

  test "channel cards select their fallback before blocked images reach the browser" do
    html =
      render_component(&Cards.channel_card/1,
        channel: %{id: 30, name: "Canal", stream_icon: @blocked_image}
      )

    refute html =~ "png.pngtree.com"
    refute html =~ "<img"
    assert html =~ "data-fallback"
  end

  test "top ten and public channel cards keep blocked images out of browser markup" do
    top_ten_html =
      render_component(&Carousel.top_10_card/1,
        movie: %{id: 40, name: "Filme", stream_icon: @blocked_image, rating: nil},
        rank: 1
      )

    public_channel_html =
      render_component(&Landing.public_channel_card/1,
        channel: %{id: 50, name: "Canal público", stream_icon: @blocked_image}
      )

    refute top_ten_html =~ "png.pngtree.com"
    refute top_ten_html =~ "<img"
    refute public_channel_html =~ "png.pngtree.com"
    refute public_channel_html =~ "<img"
  end

  test "authenticated poster carousels use two readable mobile columns" do
    movie = %{id: 60, name: "Filme", provider_id: 7}

    home_html =
      render_component(&Carousel.render_content_carousel/1,
        type: :movies,
        title: "Filmes",
        items: [movie],
        see_more_path: nil
      )

    recommendation_html =
      render_component(&ContentCarousel.for_you_section/1,
        recommendations: [movie]
      )

    assert home_html =~ "grid-cols-2"
    refute home_html =~ "grid-cols-3"
    assert recommendation_html =~ "grid-cols-2"
    refute recommendation_html =~ "grid-cols-3"
  end
end
