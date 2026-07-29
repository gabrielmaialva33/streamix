defmodule StreamixWeb.Content.CardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.Content.CardComponents

  test "limits hover-preview metadata in the initial card HTML" do
    prefix = String.duplicate("a", 240)
    plot = prefix <> "payload-that-must-not-ship"

    html =
      render_component(&CardComponents.movie_card/1,
        movie: %{
          id: 42,
          name: "Filme leve",
          plot: plot,
          provider_id: 7
        }
      )

    assert html =~ ~s(data-plot="#{prefix}")
    refute html =~ "payload-that-must-not-ship"
  end
end
