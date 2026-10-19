defmodule StreamixWeb.Api.V1.ReelsControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.Category
  alias Streamix.Repo

  setup do
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, [])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)

    %{global: global_provider_fixture(%{name: "MegaEmbed"})}
  end

  describe "GET /api/v1/catalog/reels" do
    test "lists public reels newest first with the series card shape", %{
      conn: conn,
      global: global
    } do
      asia = category!(global, "[Reels] Histórias da Ásia")
      older = global |> reel!([asia], %{name: "Older Drama", year: 2024}) |> backdate!(120)
      newer = reel!(global, [asia], %{name: "Newer Drama", year: 2025})
      _regular = series_content_fixture(global, %{name: "Regular Show"})

      private = provider_fixture(user_fixture(), %{name: "Private"})
      _private_reel = reel!(private, [category!(private, "[Reels] Histórias da Ásia")])

      response = conn |> get(~p"/api/v1/catalog/reels") |> json_response(200)

      assert Enum.map(response["data"], & &1["id"]) == [newer.id, older.id]

      assert response["meta"] == %{
               "pagination" => %{
                 "page" => 1,
                 "per_page" => 24,
                 "total" => 2,
                 "has_more" => false,
                 "next_page" => nil
               },
               "filters" => %{"category" => nil}
             }

      [card | _] = response["data"]

      assert Map.keys(card) |> Enum.sort() ==
               Enum.sort(~w(id name title year rating genre poster provider reel_category))

      assert card["reel_category"] == "Histórias da Ásia"
      assert card["provider"] == %{"id" => global.id, "name" => "MegaEmbed", "type" => "xtream"}
    end

    test "filters by category display name and pages with page/per_page", %{
      conn: conn,
      global: global
    } do
      mirror = provider_fixture(user_fixture(), %{name: "Mirror", visibility: :public})
      dubbed = category!(global, "[Reels] Série Dublada")
      mirror_dubbed = category!(mirror, "[Reels] Série Dublada")
      wolves = category!(global, "[Reels] Homem-lobo e Vampiro")

      first = global |> reel!([dubbed], %{name: "First"}) |> backdate!(300)
      second = mirror |> reel!([mirror_dubbed], %{name: "Second"}) |> backdate!(200)
      _wolf = global |> reel!([wolves], %{name: "Wolf"}) |> backdate!(100)

      page_one =
        conn
        |> get(~p"/api/v1/catalog/reels?#{%{category: "Série Dublada", per_page: 1}}")
        |> json_response(200)

      assert [%{"id" => id, "reel_category" => "Série Dublada"}] = page_one["data"]
      assert id == second.id

      assert page_one["meta"] == %{
               "pagination" => %{
                 "page" => 1,
                 "per_page" => 1,
                 "total" => 2,
                 "has_more" => true,
                 "next_page" => 2
               },
               "filters" => %{"category" => "Série Dublada"}
             }

      page_two =
        conn
        |> get(~p"/api/v1/catalog/reels?#{%{category: "Série Dublada", per_page: 1, page: 2}}")
        |> json_response(200)

      assert Enum.map(page_two["data"], & &1["id"]) == [first.id]
      assert page_two["meta"]["pagination"]["has_more"] == false
      assert page_two["meta"]["pagination"]["next_page"] == nil
    end

    test "returns an empty page for an unknown category, like the series filters", %{
      conn: conn,
      global: global
    } do
      reel!(global, [category!(global, "[Reels] Lançamentos")])

      response =
        conn
        |> get(~p"/api/v1/catalog/reels?#{%{category: "Inexistente"}}")
        |> json_response(200)

      assert response["data"] == []
      assert response["meta"]["pagination"]["total"] == 0
      assert response["meta"]["filters"] == %{"category" => "Inexistente"}
    end

    test "rejects malformed paging parameters against the published contract", %{conn: conn} do
      for {query, parameter} <- [
            {"per_page=0", "per_page"},
            {"per_page=101", "per_page"},
            {"page=0", "page"},
            {"page=abc", "page"}
          ] do
        response = conn |> get("/api/v1/catalog/reels?" <> query) |> json_response(400)

        assert response == %{
                 "error" => %{
                   "code" => "invalid_parameter",
                   "message" => "Invalid value for parameter #{parameter}"
                 }
               }
      end
    end
  end

  describe "GET /api/v1/catalog/reels/categories" do
    test "merges public categories by display name with counts", %{conn: conn, global: global} do
      mirror = provider_fixture(user_fixture(), %{name: "Mirror", visibility: :public})
      private = provider_fixture(user_fixture(), %{name: "Private"})
      adult = category!(global, "Adultos", true)

      reel!(global, [category!(global, "[Reels] Histórias da Ásia")])
      reel!(mirror, [category!(mirror, "[Reels] Histórias da Ásia")])
      reel!(mirror, [category!(mirror, "[Reels] Gênero Masculino")])
      reel!(private, [category!(private, "[Reels] Relacionamento Tabu")])
      reel!(global, [category!(global, "[Reels] Amor à Primeira Vista"), adult])

      response = conn |> get(~p"/api/v1/catalog/reels/categories") |> json_response(200)

      assert response == %{
               "data" => [
                 %{"name" => "Histórias da Ásia", "count" => 2},
                 %{"name" => "Gênero Masculino", "count" => 1}
               ],
               "meta" => %{"total" => 2}
             }
    end

    test "a listed name filters the reels, however long it is", %{conn: conn, global: global} do
      # 247 characters: the longest display name a varchar(255) category holds.
      long_name = String.duplicate("a", 247)
      drama = reel!(global, [category!(global, "[Reels] " <> long_name)])

      assert %{"data" => [%{"name" => ^long_name}]} =
               conn |> get(~p"/api/v1/catalog/reels/categories") |> json_response(200)

      response =
        conn |> get(~p"/api/v1/catalog/reels?#{%{category: long_name}}") |> json_response(200)

      assert Enum.map(response["data"], & &1["id"]) == [drama.id]
      assert response["meta"]["filters"] == %{"category" => long_name}
    end
  end

  describe "API key authentication" do
    test "both endpoints use the catalog API key pipeline", %{conn: conn} do
      Application.put_env(:streamix, :api_keys, ["reels-test-key"])

      for path <- [~p"/api/v1/catalog/reels", ~p"/api/v1/catalog/reels/categories"] do
        assert conn |> get(path) |> json_response(401) |> get_in(["error", "code"]) ==
                 "missing_api_key"

        assert build_conn()
               |> put_req_header("x-api-key", "reels-test-key")
               |> get(path)
               |> json_response(200)
               |> Map.has_key?("data")
      end
    end
  end

  defp category!(provider, name, is_adult \\ false) do
    %Category{}
    |> Category.changeset(%{
      provider_id: provider.id,
      name: name,
      type: "series",
      is_adult: is_adult,
      external_id: Integer.to_string(System.unique_integer([:positive]))
    })
    |> Repo.insert!()
  end

  defp reel!(provider, categories, attrs \\ %{}) do
    series = series_content_fixture(provider, attrs)

    Repo.insert_all(
      "item_categories",
      Enum.map(categories, &%{catalog_item_id: series.catalog_item_id, category_id: &1.id})
    )

    series
  end

  defp backdate!(series, seconds_ago) do
    inserted_at =
      DateTime.utc_now()
      |> DateTime.add(-seconds_ago, :second)
      |> DateTime.truncate(:second)

    series
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Repo.update!()
  end
end
