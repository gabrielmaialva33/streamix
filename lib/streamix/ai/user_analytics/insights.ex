defmodule Streamix.AI.UserAnalytics.Insights do
  @moduledoc false

  alias Streamix.Cache
  alias Streamix.Iptv.Genre
  alias Streamix.Iptv.History
  alias Streamix.Repo

  import Ecto.Query

  @recommendations_ttl 3600

  @doc """
  Gets viewing insights for a user.

  Returns aggregated stats about their viewing habits:
  - Favorite genres
  - Watch time patterns (weekday vs weekend, time of day)
  - Content type preferences
  - Completion rate
  """
  def get_user_insights(user_id) do
    cache_key = "user_insights:#{user_id}"

    Cache.fetch(cache_key, @recommendations_ttl, fn ->
      history = History.list_for_analytics(user_id, limit: 500)

      if Enum.empty?(history) do
        %{has_data: false}
      else
        %{
          has_data: true,
          total_items: length(history),
          content_breakdown: History.count_by_type(user_id),
          completion_rate: calculate_completion_rate(history),
          favorite_genres: extract_favorite_genres(user_id),
          watch_patterns: analyze_watch_patterns(history),
          most_watched_day: get_most_watched_day(history),
          avg_session_length: calculate_avg_session(history)
        }
      end
    end)
  end

  defp calculate_completion_rate(history) do
    if Enum.empty?(history) do
      0.0
    else
      completed = Enum.count(history, & &1.completed)
      Float.round(completed / length(history) * 100, 1)
    end
  end

  defp extract_favorite_genres(user_id) do
    history = History.list_for_analytics(user_id, content_type: "movie", limit: 100)
    movie_ids = Enum.map(history, & &1.content_id)

    if Enum.empty?(movie_ids) do
      []
    else
      Genre
      |> join(:inner, [genre], movie_genres in "movie_genres",
        on: movie_genres.genre_id == genre.id
      )
      |> where([genre, movie_genres], movie_genres.movie_id in ^movie_ids)
      |> select([genre, _movie_genres], genre.name)
      |> Repo.all()
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_genre, count} -> count end, :desc)
      |> Enum.take(5)
      |> Enum.map(fn {genre, _count} -> genre end)
    end
  end

  defp analyze_watch_patterns(history) do
    by_hour =
      history
      |> Enum.group_by(fn entry -> entry.watched_at.hour end)
      |> Enum.map(fn {hour, entries} -> {hour, length(entries)} end)
      |> Enum.sort_by(fn {_hour, count} -> count end, :desc)

    peak_hour =
      case by_hour do
        [{hour, _count} | _] -> hour
        _ -> nil
      end

    by_day =
      history
      |> Enum.group_by(fn entry -> Date.day_of_week(DateTime.to_date(entry.watched_at)) end)
      |> Enum.map(fn {day, entries} -> {day, length(entries)} end)

    weekend_count =
      by_day
      |> Enum.filter(fn {day, _count} -> day in [6, 7] end)
      |> Enum.reduce(0, fn {_day, count}, acc -> acc + count end)

    weekday_count =
      by_day
      |> Enum.filter(fn {day, _count} -> day in [1, 2, 3, 4, 5] end)
      |> Enum.reduce(0, fn {_day, count}, acc -> acc + count end)

    %{
      peak_hour: peak_hour,
      weekend_preference: weekend_count > weekday_count,
      weekday_count: weekday_count,
      weekend_count: weekend_count
    }
  end

  defp get_most_watched_day(history) do
    history
    |> Enum.group_by(fn entry -> Date.day_of_week(DateTime.to_date(entry.watched_at)) end)
    |> Enum.max_by(fn {_day, entries} -> length(entries) end, fn -> {1, []} end)
    |> elem(0)
    |> day_number_to_name()
  end

  defp day_number_to_name(1), do: "Segunda"
  defp day_number_to_name(2), do: "Terça"
  defp day_number_to_name(3), do: "Quarta"
  defp day_number_to_name(4), do: "Quinta"
  defp day_number_to_name(5), do: "Sexta"
  defp day_number_to_name(6), do: "Sábado"
  defp day_number_to_name(7), do: "Domingo"
  defp day_number_to_name(_), do: "Desconhecido"

  defp calculate_avg_session(history) do
    durations = history |> Enum.map(& &1.duration_seconds) |> Enum.reject(&is_nil/1)

    if Enum.empty?(durations) do
      0
    else
      avg = Enum.sum(durations) / length(durations)
      round(avg / 60)
    end
  end
end
