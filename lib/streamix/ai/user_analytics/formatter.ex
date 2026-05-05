defmodule Streamix.AI.UserAnalytics.Formatter do
  @moduledoc false

  def recommendations(results) do
    Enum.map(results, fn %{id: id, score: score, payload: payload} ->
      %{
        id: id,
        score: Float.round(score, 3),
        title: payload["title"],
        year: payload["year"],
        genre: payload["genre"],
        rating: payload["rating"]
      }
    end)
  end
end
