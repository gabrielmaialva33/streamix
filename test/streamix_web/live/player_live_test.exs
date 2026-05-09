defmodule StreamixWeb.PlayerLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures

  alias Streamix.Billing.Plan
  alias Streamix.Billing.Subscription
  alias Streamix.Iptv.{Episode, Season}
  alias Streamix.Repo

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
