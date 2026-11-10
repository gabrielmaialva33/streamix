defmodule StreamixWeb.Gindex.EpisodeComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias StreamixWeb.Gindex.EpisodeComponents

  test "renders the shared play event, episode title and container badge" do
    html =
      render_component(&EpisodeComponents.episode_item/1,
        episode: %{
          id: 9,
          episode_num: 2,
          title: "Piloto",
          name: "Piloto",
          container_extension: "mkv"
        },
        season_number: 1
      )

    assert html =~ ~s(phx-click="play_episode")
    assert html =~ ~s(phx-value-id="9")
    assert html =~ "Piloto"
    assert html =~ "MKV"
  end
end
