defmodule Streamix.AI.UserAnalytics.Indexing do
  @moduledoc false

  require Logger

  alias Streamix.AI.Embeddings
  alias Streamix.AI.Qdrant
  alias Streamix.AI.UserAnalytics.Content

  @doc """
  Indexes a content item in Qdrant for recommendations.

  Call this after syncing content or enriching with TMDB data.
  """
  def index_content(content, collection) do
    text = Content.text(content)

    case Embeddings.embed(text) do
      {:ok, vector} ->
        Qdrant.upsert_point(collection, content.id, vector, Content.payload(content))

      {:error, reason} ->
        Logger.warning(
          "[UserAnalytics] Failed to embed content #{content.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Indexes multiple content items in batch.
  """
  def index_contents(contents, collection) do
    texts = Enum.map(contents, &Content.text/1)

    case Embeddings.embed_batch(texts) do
      {:ok, vectors} ->
        points =
          contents
          |> Enum.zip(vectors)
          |> Enum.map(fn {content, vector} ->
            {content.id, vector, Content.payload(content)}
          end)

        Qdrant.upsert_points(collection, points)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
