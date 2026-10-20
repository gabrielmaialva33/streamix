defmodule StreamixWeb.Api.V1.RecommendationsControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.{Accounts, Billing}

  setup do
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, [])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)
    :ok
  end

  test "channel recommendations serialize category data without crashing", %{conn: conn} do
    user = user_fixture()
    provider = provider_fixture(user)
    channel = channel_fixture(provider)
    grant_ai_recommendations!(user)

    response =
      conn
      |> authenticated(user)
      |> get(~p"/api/v1/recommendations/channels")
      |> json_response(200)

    assert [%{"id" => id, "category" => nil, "categories" => []}] = response["channels"]
    assert id == channel.id
  end

  test "movie and series recommendations include both genre string and canonical genres array", %{
    conn: conn
  } do
    user = user_fixture()
    provider = global_provider_fixture()
    grant_ai_recommendations!(user)

    movie =
      provider
      |> movie_fixture(%{name: "Recommended Movie", title: "Recommended Movie", year: 2025})
      |> Ecto.Changeset.change(%{
        stream_icon: "https://img.example.test/rec-movie.jpg",
        rating: Decimal.new("8.5")
      })
      |> Streamix.Repo.update!()

    series =
      provider
      |> series_content_fixture(%{
        name: "Recommended Series",
        title: "Recommended Series",
        year: 2025
      })
      |> Ecto.Changeset.change(%{
        cover: "https://img.example.test/rec-series.jpg",
        rating: Decimal.new("8.5")
      })
      |> Streamix.Repo.update!()

    acao =
      Streamix.Repo.insert!(
        %Streamix.Iptv.Genre{slug: "acao", name: "Ação", position: 1},
        on_conflict: {:replace, [:name, :position]},
        conflict_target: :slug
      )
      |> then(fn _ -> Streamix.Repo.get_by!(Streamix.Iptv.Genre, slug: "acao") end)

    drama =
      Streamix.Repo.insert!(
        %Streamix.Iptv.Genre{slug: "drama", name: "Drama", position: 7},
        on_conflict: {:replace, [:name, :position]},
        conflict_target: :slug
      )
      |> then(fn _ -> Streamix.Repo.get_by!(Streamix.Iptv.Genre, slug: "drama") end)

    Streamix.Repo.insert_all("movie_genres", [
      %{movie_id: movie.id, genre_id: drama.id},
      %{movie_id: movie.id, genre_id: acao.id}
    ])

    Streamix.Repo.insert_all("series_genres", [
      %{series_id: series.id, genre_id: drama.id}
    ])

    Streamix.Cache.set(
      Streamix.Cache.recommendations_key(user.id, "movies", 80, true),
      [%{id: movie.id, score: 0.91}],
      60
    )

    Streamix.Cache.set(
      Streamix.Cache.recommendations_key(user.id, "series", 80, true),
      [%{id: series.id, score: 0.88}],
      60
    )

    movie_resp =
      conn
      |> authenticated(user)
      |> get(~p"/api/v1/recommendations?type=movies")
      |> json_response(200)

    [rec_movie] = Enum.filter(movie_resp["recommendations"], &(&1["id"] == movie.id))
    assert rec_movie["genre"] == "Ação, Drama"

    assert rec_movie["genres"] == [
             %{"slug" => "acao", "name" => "Ação"},
             %{"slug" => "drama", "name" => "Drama"}
           ]

    series_resp =
      conn
      |> authenticated(user)
      |> get(~p"/api/v1/recommendations?type=series")
      |> json_response(200)

    [rec_series] = Enum.filter(series_resp["recommendations"], &(&1["id"] == series.id))
    assert rec_series["genre"] == "Drama"
    assert rec_series["genres"] == [%{"slug" => "drama", "name" => "Drama"}]
  end

  defp grant_ai_recommendations!(user) do
    unique = System.unique_integer([:positive])

    {:ok, plan} =
      Billing.create_plan(%{
        name: "AI #{unique}",
        slug: "ai-#{unique}",
        price_cents: 0,
        currency: "BRL",
        billing_interval: "month",
        features: %{"ai_recommendations" => true}
      })

    {:ok, _subscription} =
      Billing.create_manual_subscription(user, plan, %{
        status: "active",
        starts_at: DateTime.utc_now(:second)
      })
  end

  defp authenticated(conn, user) do
    token = Accounts.generate_user_session_token(user)
    put_req_header(conn, "authorization", "Bearer #{Base.url_encode64(token)}")
  end
end
