defmodule Streamix.AI.UserAnalytics.Content do
  @moduledoc false

  def text(content) do
    parts = [
      content.name || content.title,
      Map.get(content, :plot),
      Map.get(content, :genre),
      Map.get(content, :cast),
      Map.get(content, :director)
    ]

    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  def payload(content) do
    %{
      title: content.name || content.title,
      year: Map.get(content, :year),
      genre: Map.get(content, :genre),
      rating: Map.get(content, :rating),
      provider_id: Map.get(content, :provider_id)
    }
  end
end
