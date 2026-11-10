defmodule StreamixWeb.SearchLiveTest do
  use StreamixWeb.ConnCase

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.AI.Embeddings

  setup do
    user = user_fixture()

    global =
      provider_fixture(user, %{
        name: "Global Catalog",
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    %{user: user, global: global}
  end

  describe "result cards" do
    test "clicking a movie poster navigates to the movie detail", %{
      conn: conn,
      user: user,
      global: global
    } do
      movie = movie_fixture(global, %{name: "Search Click Movie", year: 2024})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/search?q=Search+Click")

      assert has_element?(view, "#movie-card-#{movie.id}")
      assert has_element?(view, "#search-filter-strip[data-filter-strip]")

      view
      |> element("#movie-card-#{movie.id} > [data-media-primary]")
      |> render_click()

      assert_redirect(
        view,
        "/browse/movies/#{movie.id}?return_to=%2Fsearch%3Fq%3DSearch%2BClick"
      )
    end

    test "clicking a series poster navigates to the series detail", %{
      conn: conn,
      user: user,
      global: global
    } do
      series = series_content_fixture(global, %{name: "Search Click Series", year: 2024})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/search?q=Search+Click")

      assert has_element?(view, "#series-card-#{series.id}")

      view
      |> element("#series-card-#{series.id} > [data-media-primary]")
      |> render_click()

      assert_redirect(
        view,
        "/browse/series/#{series.id}?return_to=%2Fsearch%3Fq%3DSearch%2BClick"
      )
    end

    test "initial and empty states provide bounded status surfaces", %{
      conn: conn,
      user: user
    } do
      conn = log_in_user(conn, user)
      {:ok, initial_view, _html} = live(conn, ~p"/search")

      assert has_element?(initial_view, "#search-hints.border")

      {:ok, empty_view, html} = live(conn, ~p"/search?q=zzzz-no-streamix-result-zzzz")

      assert has_element?(empty_view, "#search-empty[role='status']")
      assert html =~ "zzzz-no-streamix-result-zzzz"
    end

    test "renders the complete first page and can load every remaining result", %{
      conn: conn,
      user: user,
      global: global
    } do
      movies =
        for index <- 1..25 do
          suffix = String.pad_leading(Integer.to_string(index), 2, "0")

          movie_fixture(global, %{
            name: "Busca Completa #{suffix}",
            title: "Busca Completa #{suffix}"
          })
        end

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/search?q=Busca+Completa")

      assert has_element?(view, "#movie-card-#{Enum.at(movies, 6).id}")
      assert has_element?(view, "#movie-card-#{Enum.at(movies, 23).id}")
      refute has_element?(view, "#movie-card-#{Enum.at(movies, 24).id}")

      # "Todos" previews the type; its filter has the whole list.
      assert has_element?(view, "#search-movies-grid.search-preview")
      assert has_element?(view, "#search-see-all-movies", "Ver os 24+ filmes")
      refute has_element?(view, "#search-load-more-movies")

      view |> element("#search-see-all-movies") |> render_click()

      assert has_element?(view, "#search-filter-movies[aria-pressed='true']")
      refute has_element?(view, "#search-movies-grid.search-preview")
      assert has_element?(view, "#search-load-more-movies[phx-click='load_more']")

      view
      |> element("#search-load-more-movies")
      |> render_click()

      assert has_element?(view, "#movie-card-#{Enum.at(movies, 24).id}")
      refute has_element?(view, "#search-load-more-movies")

      view
      |> element("#movie-card-#{Enum.at(movies, 24).id} button[phx-click='toggle_favorite']")
      |> render_click()

      assert has_element?(view, "#movie-card-#{Enum.at(movies, 24).id}")

      assert has_element?(
               view,
               "#movie-card-#{Enum.at(movies, 24).id} button[aria-label='Remover dos favoritos']"
             )

      refute has_element?(view, "#search-load-more-movies")
    end

    test "does not truncate channel and series sections to six cards", %{
      conn: conn,
      user: user,
      global: global
    } do
      channels =
        for index <- 1..7 do
          channel_fixture(global, %{name: "Busca Sete Canal #{index}"})
        end

      series =
        for index <- 1..7 do
          series_content_fixture(global, %{
            name: "Busca Sete Série #{index}",
            title: "Busca Sete Série #{index}"
          })
        end

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/search?q=Busca+Sete")

      assert has_element?(view, "#channel-img-#{List.last(channels).id}")
      assert has_element?(view, "#series-card-#{List.last(series).id}")
    end

    test "keeps streamed cards mounted while switching filters", %{
      conn: conn,
      user: user,
      global: global
    } do
      channel = channel_fixture(global, %{name: "Busca Persistente Canal"})

      movie =
        movie_fixture(global, %{
          name: "Busca Persistente Filme",
          title: "Busca Persistente Filme"
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/search?q=Busca+Persistente")

      view |> element("#search-filter-channels") |> render_click()
      assert has_element?(view, "#channel-img-#{channel.id}")

      view |> element("#search-filter-all") |> render_click()
      assert has_element?(view, "#movie-card-#{movie.id}")
    end
  end

  describe "Descobrir" do
    test "a plain title word gets no discovery row", %{conn: conn, user: user, global: global} do
      movie_fixture(global, %{name: "Interestelar", title: "Interestelar"})

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/search?q=Interestelar")

      refute has_element?(view, "#search-discover-section")
    end

    test "a descriptive query shows what was understood and the matching titles",
         %{conn: conn, user: user, global: global} do
      movie =
        movie_fixture(global, %{name: "Noite do Terror", title: "Noite do Terror", year: 1984})

      private_provider = provider_fixture(user_fixture(), %{visibility: "private"})
      hidden = movie_fixture(private_provider, %{name: "Oculto", title: "Oculto"})
      stub_semantic_search(%{"movies" => [movie.id, hidden.id]})

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/search?q=terror+anos+80")
      html = render_async(view)

      assert has_element?(view, "#search-discover-section")
      assert has_element?(view, "#search-discover-movies #movie-card-#{movie.id}")
      refute has_element?(view, "#movie-card-#{hidden.id}")
      assert html =~ "Anos 80"
      # Nothing matched the title, but discovery did: no empty state.
      refute has_element?(view, "#search-empty")

      assert_received {:qdrant_search, "movies", filter}
      assert %{"key" => "genres", "match" => %{"any" => ["Terror"]}} in filter["must"]
      assert %{"key" => "provider_id", "match" => %{"any" => visible}} = hd(filter["must"])
      refute private_provider.id in visible
    end

    # Semantic search counts as available only when the embedding provider
    # answers and the collections match its dimensions, so all of it is faked.
    defp stub_semantic_search(hits) do
      saved =
        for key <- [:qdrant, :gemini, :embeddings], do: {key, Application.get_env(:streamix, key)}

      req = Req.default_options()
      owner = self()

      Application.put_env(:streamix, :qdrant, enabled: true, url: "http://qdrant.test")
      Application.put_env(:streamix, :gemini, api_key: "search-live-test")
      Application.put_env(:streamix, :embeddings, provider: "gemini")
      Req.default_options(plug: {Req.Test, __MODULE__})
      Req.Test.set_req_test_to_shared()

      on_exit(fn ->
        Enum.each(saved, &restore_env/1)
        Req.default_options(req)
        Req.Test.set_req_test_to_private()
      end)

      dimensions = Embeddings.embedding_dimensions()
      Req.Test.stub(__MODULE__, &semantic_stub(&1, owner, hits, dimensions))
    end

    defp restore_env({key, nil}), do: Application.delete_env(:streamix, key)
    defp restore_env({key, value}), do: Application.put_env(:streamix, key, value)

    defp semantic_stub(conn, owner, hits, dimensions) do
      case {conn.host, conn.method, conn.path_info} do
        {"qdrant.test", "GET", ["collections", _name]} ->
          vectors = %{"vectors" => %{"size" => dimensions}}

          Req.Test.json(conn, %{
            "result" => %{"status" => "green", "config" => %{"params" => vectors}}
          })

        {"qdrant.test", "POST", ["collections", name, "points", "search"]} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(owner, {:qdrant_search, name, Jason.decode!(raw)["filter"]})
          Req.Test.json(conn, %{"result" => search_points(Map.get(hits, name, []))})

        _gemini ->
          Req.Test.json(conn, %{"embedding" => %{"values" => List.duplicate(0.01, dimensions)}})
      end
    end

    defp search_points(ids) do
      for {id, index} <- Enum.with_index(ids) do
        %{"id" => id, "score" => 0.9 - index / 10, "payload" => %{"variant_key" => "k#{id}"}}
      end
    end
  end
end
