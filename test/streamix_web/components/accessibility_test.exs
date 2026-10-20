defmodule StreamixWeb.AccessibilityTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias StreamixWeb.App.Premium
  alias StreamixWeb.Content.DetailComponents
  alias StreamixWeb.Home.Carousel

  test "premium banner fills nil copy without replacing explicit overrides" do
    html =
      render_component(&Premium.premium_cta_banner/1,
        title: nil,
        description: nil,
        cta_label: nil
      )

    assert html =~ "Conheça os planos do Streamix"
    assert html =~ "Acesse o catálogo global"
    assert html =~ "Explorar planos"

    custom =
      render_component(&Premium.premium_cta_banner/1,
        title: "Título",
        description: "Descrição",
        cta_label: "Abrir"
      )

    assert custom =~ "Título"
    assert custom =~ "Descrição"
    assert custom =~ "Abrir"
  end

  test "carousel controls name their shelf and start disabled until measured" do
    html =
      render_component(&Carousel.carousel_arrows/1, id: "rail", title: "Top 10", inner_block: [])

    doc = LazyHTML.from_fragment(html)

    assert LazyHTML.attribute(LazyHTML.query(doc, "button[data-scroll-dir=right]"), "aria-label") ==
             ["Rolar Top 10 para a direita"]

    assert LazyHTML.query(doc, "button[disabled]") |> Enum.count() == 2
  end

  test "gallery has a labelled native modal and restores the selected image trigger" do
    html =
      render_component(&DetailComponents.gallery_preview/1,
        image: "/image.jpg",
        alt: "Imagem do filme"
      )

    doc = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             doc,
             "dialog[aria-label='Imagem do filme'][data-close-event=close_gallery_preview]"
           )
           |> Enum.count() == 1

    [selector] = LazyHTML.attribute(LazyHTML.query(doc, "dialog"), "data-return-focus")

    gallery =
      render_component(&DetailComponents.image_gallery/1, images: ["/other.jpg", "/image.jpg"])

    assert gallery |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count() == 1
  end
end
