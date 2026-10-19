defmodule Streamix.AI.ScoreThresholds do
  @moduledoc """
  Minimum cosine similarity a Qdrant hit must reach, per kind of comparison.

  The floors belong to the embedding model, not to the feature: every model
  spreads cosine scores differently, so a floor tuned for one model silently
  empties results on another. The previous nv-embedqa generation scored
  relevant hits around 0.6–0.8, and the hard-coded 0.5–0.7 floors left from it
  dropped every result once production moved to `nvidia/nemotron-3-embed-1b`.

  Measured on 2026-10-19 against the production `animes` collection
  (nemotron-3-embed-1b, 2048 dimensions):

    * `:query` — text query against stored titles. Relevant hits scored
      0.24–0.51 ("anime de ninja" → Ninja Slayer 0.509); an off-topic query
      ("receita de bolo de chocolate") topped out at 0.224.
    * `:similar` — one stored title against the others. Nearest neighbours
      scored 0.42–0.56, so 0.40 keeps the real neighbours and drops the tail.
    * `:profile` — a user profile (the mean of watched titles' vectors)
      against titles. Averaged vectors score a little below title-to-title.

  Re-measure and update these when the embedding model changes. They can be
  overridden without a code change through
  `config :streamix, :semantic_scores, query: …, similar: …, profile: …`.
  """

  @defaults [query: 0.25, similar: 0.40, profile: 0.35]

  @doc "Floor for a free-text query against stored titles."
  @spec query() :: float()
  def query, do: get(:query)

  @doc "Floor for a stored title against the other titles."
  @spec similar() :: float()
  def similar, do: get(:similar)

  @doc "Floor for a user profile vector against titles."
  @spec profile() :: float()
  def profile, do: get(:profile)

  defp get(kind) do
    :streamix
    |> Application.get_env(:semantic_scores, [])
    |> Keyword.get(kind, Keyword.fetch!(@defaults, kind))
  end
end
