defmodule StreamixWeb.PlayerLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures

  alias Streamix.Billing.Plan
  alias Streamix.Billing.Subscription
  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Repo
  alias Streamix.Torrent.TorrentStream
  alias StreamixWeb.PlayerHelpers

  defp plan_fixture(attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        name: "Premium",
        slug: "premium-#{System.unique_integer([:positive])}",
        description: "Acesso global ao catálogo e recursos premium.",
        price_cents: 1_999,
        currency: "BRL",
        billing_interval: "month",
        active: true,
        grants_global_access: true
      })

    %Plan{}
    |> Plan.changeset(params)
    |> Repo.insert!()
  end

  defp subscription_fixture(user, plan, attrs \\ %{}) do
    params =
      Enum.into(attrs, %{
        status: "active",
        starts_at: DateTime.utc_now(),
        expires_at: nil,
        canceled_at: nil,
        source: "stripe",
        external_reference: "sub_test_#{System.unique_integer([:positive])}"
      })

    %Subscription{}
    |> Subscription.create_changeset(user, plan, params)
    |> Repo.insert!()
  end

  defp global_gindex_provider_fixture(user, attrs \\ %{}) do
    provider_fixture(
      user,
      Enum.into(attrs, %{
        visibility: "global",
        is_system: true,
        provider_type: :gindex,
        is_active: true,
        url: "http://127.0.0.1:65535",
        gindex_url: "http://127.0.0.1:65535"
      })
    )
  end

  describe "mount access control" do
    setup :register_and_log_in_user

    test "rejects malformed ids before querying Ecto" do
      assert {:error, :not_found} = PlayerHelpers.load_content_preflight("movie", "nope", 1)
      assert {:error, :not_found} = PlayerHelpers.load_content_preflight("episode", "nope", 1)

      assert {:error, :not_found} =
               PlayerHelpers.load_content_preflight("live_channel", "nope", 1)

      assert {:error, :not_found} = PlayerHelpers.load_content_preflight("gindex", "nope", 1)

      assert {:error, :not_found} =
               PlayerHelpers.load_content_preflight("gindex_episode", "nope", 1)
    end

    test "torrent preflight carries the movie IMDb id into player content", %{user: user} do
      provider =
        provider_fixture(user, %{
          visibility: "private",
          is_system: false,
          provider_type: "torrent",
          is_active: true
        })

      movie = movie_fixture(provider, %{name: "Torrent Legendado", imdb_id: "tt15047880"})
      info_hash = :crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)

      stream =
        %TorrentStream{}
        |> TorrentStream.changeset(%{
          info_hash: info_hash,
          magnet_uri: "magnet:?xt=urn:btih:#{info_hash}",
          source_slug: "test",
          movie_id: movie.id
        })
        |> Repo.insert!()

      assert {:ok, content, loaded_provider} =
               PlayerHelpers.load_content_preflight("torrent", stream.id, user.id)

      assert content.imdb_id == "tt15047880"
      assert loaded_provider.id == provider.id
    end

    test "customer without subscription is redirected to /plans when opening global content", %{
      conn: conn,
      user: user
    } do
      provider =
        provider_fixture(user, %{
          visibility: "global",
          is_system: true,
          provider_type: "xtream",
          is_active: true
        })

      channel = channel_fixture(provider, %{name: "Canal Global Bloqueado"})

      result = live(conn, ~p"/watch/live_channel/#{channel.id}")

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} = result
      assert to == ~p"/plans"
      assert flash["error"] =~ "assinatura"

      {:ok, _plans_view, html} = follow_redirect(result, conn, ~p"/plans")
      refute html =~ "Canal Global Bloqueado"
    end

    test "customer without subscription is redirected to /plans when opening global movie content",
         %{
           conn: conn,
           user: user
         } do
      provider =
        provider_fixture(user, %{
          visibility: "global",
          is_system: true,
          provider_type: "xtream",
          is_active: true
        })

      movie = movie_fixture(provider, %{title: "Filme Global Bloqueado", name: "Filme Global"})

      result = live(conn, ~p"/watch/movie/#{movie.id}")

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} = result
      assert to == ~p"/plans"
      assert flash["error"] =~ "assinatura"
    end

    test "customer without subscription is redirected to /plans before resolving gindex content",
         %{
           conn: conn,
           user: user
         } do
      provider = global_gindex_provider_fixture(user)

      movie =
        movie_fixture(provider, %{name: "GIndex Bloqueado", gindex_path: "/1:/Filmes/demo.mp4"})

      result = live(conn, ~p"/watch/gindex/#{movie.id}")

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} = result
      assert to == ~p"/plans"
      assert flash["error"] =~ "assinatura"
    end

    test "customer with active subscription can open global content", %{conn: conn, user: user} do
      plan = plan_fixture()
      _subscription = subscription_fixture(user, plan)

      provider =
        provider_fixture(user, %{
          visibility: "global",
          is_system: true,
          provider_type: "xtream",
          is_active: true
        })

      channel = channel_fixture(provider, %{name: "Canal Global Permitido"})

      {:ok, _view, html} = live(conn, ~p"/watch/live_channel/#{channel.id}")

      assert html =~ "Canal Global Permitido"
    end

    test "private and public content owned by the user still opens without subscription", %{
      conn: conn,
      user: user
    } do
      for visibility <- ["private", "public"] do
        provider =
          provider_fixture(user, %{
            visibility: visibility,
            is_system: false,
            provider_type: "xtream",
            is_active: true
          })

        channel = channel_fixture(provider, %{name: "#{String.capitalize(visibility)} Canal"})

        {:ok, _view, html} = live(conn, ~p"/watch/live_channel/#{channel.id}")

        assert html =~ "#{String.capitalize(visibility)} Canal"
      end
    end

    test "close player returns to safe return path", %{conn: conn, user: user} do
      provider =
        provider_fixture(user, %{
          visibility: "private",
          is_system: false,
          provider_type: "xtream",
          is_active: true
        })

      movie = movie_fixture(provider, %{name: "Returnable Movie"})

      {:ok, view, html} =
        live(conn, ~p"/watch/movie/#{movie.id}?return_to=/browse/movies/#{movie.id}")

      return_path = "/browse/movies/#{movie.id}"

      assert html =~ ~s(id="player-close-btn")
      assert html =~ "player-safe-top"
      assert html =~ "player-flash-stack"
      assert html =~ "size-12"

      assert {:error, {:redirect, %{status: 302, to: ^return_path}}} =
               render_hook(view, "close_player", %{})
    end

    test "close player ignores unsafe return path", %{conn: conn, user: user} do
      provider =
        provider_fixture(user, %{
          visibility: "private",
          is_system: false,
          provider_type: "xtream",
          is_active: true
        })

      movie = movie_fixture(provider, %{name: "Unsafe Return Movie"})

      {:ok, view, _html} = live(conn, ~p"/watch/movie/#{movie.id}?return_to=//evil.test")
      return_path = "/providers/#{provider.id}/movies"

      assert {:error, {:redirect, %{status: 302, to: ^return_path}}} =
               render_hook(view, "close_player", %{})
    end

    test "adjusts subtitle sync from the player settings menu", %{conn: conn, user: user} do
      provider =
        provider_fixture(user, %{
          visibility: "private",
          is_system: false,
          provider_type: "xtream",
          is_active: true
        })

      movie = movie_fixture(provider, %{name: "Filme com legenda"})

      {:ok, view, html} = live(conn, ~p"/watch/movie/#{movie.id}")

      assert html =~ ~s(id="subtitle-sync-controls")
      assert html =~ ~s(id="subtitle-sync-value")
      assert html =~ "0s"

      render_click(view, "adjust_subtitle_offset", %{"delta" => "500"})

      assert_push_event(view, "subtitle_offset_changed", %{offset_ms: 500})
      assert Streamix.Accounts.get_user!(user.id).subtitle_offset_ms == 500
      assert render(view) =~ "+0.5s"

      render_click(view, "reset_subtitle_offset")

      assert_push_event(view, "subtitle_offset_changed", %{offset_ms: 0})
      assert Streamix.Accounts.get_user!(user.id).subtitle_offset_ms == 0
    end

    test "torrent buffering gate keeps a safe-area-aware close button visible" do
      html =
        render_component(&StreamixWeb.PlayerComponents.torrent_swarm_gate/1,
          content: %{title: "Torrent Movie", name: "Torrent Movie"},
          status_url: "/api/torrent/status/demo",
          on_close: "close_player"
        )

      assert html =~ ~s(id="torrent-swarm-close-btn")
      assert html =~ "player-safe-corner"
      assert html =~ "size-12"
      assert html =~ ~s(aria-label="Fechar player")
    end

    test "owned episode opens with series subtitle metadata", %{conn: conn, user: user} do
      provider =
        provider_fixture(user, %{
          visibility: "private",
          is_system: false,
          provider_type: "xtream",
          is_active: true
        })

      series = series_content_fixture(provider, %{name: "Bleach [L]"})

      season =
        %Season{}
        |> Season.changeset(%{
          season_number: 1,
          name: "Temporada 1",
          series_id: series.id
        })
        |> Repo.insert!()

      catalog_item = catalog_item_fixture("episode", provider.id)

      episode =
        %Episode{}
        |> Episode.changeset(%{
          episode_id: System.unique_integer([:positive]),
          episode_num: 1,
          title: "S01E01",
          container_extension: "mp4",
          season_id: season.id
        })
        |> Ecto.Changeset.put_change(:catalog_item_id, catalog_item.id)
        |> Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/watch/episode/#{episode.id}")

      assert html =~ "S01E01"
      assert html =~ "Bleach [L] - T1:E1"
    end
  end
end
