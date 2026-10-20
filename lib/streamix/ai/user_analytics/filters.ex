defmodule Streamix.AI.UserAnalytics.Filters do
  @moduledoc false

  alias Streamix.AI.UserAnalytics.Insights
  alias Streamix.Catalog

  @default_genre_slugs ~w(acao comedia drama terror ficcao-cientifica animacao)

  @doc """
  Gets user's favorite genres for dynamic filter options.

  Returns list of {value, label} tuples for dropdown.
  """
  def get_user_genre_filters(nil), do: default_genre_filters()

  def get_user_genre_filters(user_id) do
    case Insights.get_user_insights(user_id) do
      %{favorite_genres: [_ | _] = genres} ->
        user_genres =
          genres
          |> Enum.flat_map(&Catalog.genre_slugs/1)
          |> Enum.uniq()
          |> Enum.take(5)
          |> Enum.map(fn slug -> {slug, Catalog.genre_name(slug)} end)

        case user_genres do
          [] -> default_genre_filters()
          _ -> [{"all", "Todos"} | user_genres]
        end

      _ ->
        default_genre_filters()
    end
  end

  @doc """
  Gets period filter options.
  """
  def get_period_filters do
    [
      {7, "7 dias"},
      {30, "30 dias"},
      {nil, "Todos"}
    ]
  end

  @doc """
  Gets channel category filters.
  """
  def get_channel_category_filters do
    [
      {"all", "Todos"},
      {"sports", "Esportes"},
      {"movies", "Filmes"},
      {"news", "Notícias"},
      {"kids", "Infantil"}
    ]
  end

  defp default_genre_filters do
    [
      {"all", "Todos"}
      | Enum.map(@default_genre_slugs, fn slug -> {slug, Catalog.genre_name(slug)} end)
    ]
  end
end
