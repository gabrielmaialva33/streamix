defmodule StreamixWeb.WatchPartyComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StreamixWeb.WatchPartyComponents

  test "invite_badge renders copy feedback elements and attributes (AGY-04)" do
    html =
      render_component(&WatchPartyComponents.invite_badge/1,
        invite_code: "abc12345"
      )

    document = Floki.parse_fragment!(html)
    assert [{"button", attrs, _}] = Floki.find(document, "button")
    class = List.keyfind(attrs, "class", 0) |> elem(1)
    assert class =~ "data-[copied=true]:bg-success/20"
    assert Floki.find(document, "span.hero-check") != []
    assert Floki.text(document) =~ "Copiado!"
  end

  test "chat_sidebar renders 65dvh height, 20% backdrop, 44px send button (AGY-02, AGY-06)" do
    html =
      render_component(&WatchPartyComponents.chat_sidebar/1,
        messages: [],
        room_id: 1,
        presences: %{
          "u1" => %{
            metas: [%{label: "Alice", is_host: true, joined_at: ~U[2026-01-01 00:00:00Z]}]
          }
        },
        invite_code: "code123"
      )

    document = Floki.parse_fragment!(html)

    # Backdrop has reduced dimming (bg-black/20)
    assert [{"div", backdrop_attrs, _}] = Floki.find(document, "div.fixed.inset-0")
    backdrop_class = List.keyfind(backdrop_attrs, "class", 0) |> elem(1)
    assert backdrop_class =~ "bg-black/20"
    refute backdrop_class =~ "bg-black/40"

    # Aside sheet height is 65dvh on mobile
    assert [{"aside", aside_attrs, _}] = Floki.find(document, "#watch-party-chat")
    aside_class = List.keyfind(aside_attrs, "class", 0) |> elem(1)
    assert aside_class =~ "h-[65dvh]"

    # Send button is 44px
    assert [{"button", send_attrs, _}] = Floki.find(document, "button[type='submit']")
    send_class = List.keyfind(send_attrs, "class", 0) |> elem(1)
    assert send_class =~ "size-11"
    assert send_class =~ "min-h-11"
    assert send_class =~ "min-w-11"

    # Reaction bar has stable id for mobile collapse
    assert Floki.find(document, "#wp-chat-reaction-bar") != []

    # Mobile header includes presences and invite badge
    assert Floki.find(document, "#watch-party-chat .sm\\:hidden") != []
  end
end
