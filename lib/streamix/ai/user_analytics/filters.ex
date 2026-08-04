defmodule Streamix.AI.UserAnalytics.Filters do
  @moduledoc false

  alias Streamix.AI.UserAnalytics.Insights

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
          |> Enum.take(5)
          |> Enum.map(fn genre -> {String.downcase(genre), genre} end)

        [{"all", "Todos"}] ++ user_genres

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
      {"all", "Todos"},
      {"action", "Ação"},
      {"comedy", "Comédia"},
      {"drama", "Drama"},
      {"horror", "Terror"},
      {"sci-fi", "Ficção"},
      {"animation", "Animação"}
    ]
  end
end
