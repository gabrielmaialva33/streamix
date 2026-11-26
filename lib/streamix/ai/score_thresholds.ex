defmodule Streamix.AI.ScoreThresholds do
  @moduledoc """
  Minimum cosine similarity a Qdrant hit must reach, per kind of comparison.

  The floors belong to the embedding model, not to the feature: every model
  spreads cosine scores differently, so a floor tuned for one model silently
  empties results on another. The previous nv-embedqa generation scored
  relevant hits around 0.6–0.8, and the hard-coded 0.5–0.7 floors left from it
  dropped every result once production moved to `nvidia/nemotron-3-embed-1b`,
  and the floors tuned for that one let off-topic hits through on its 3.5
  successor.

  Measured on 2026-11-26 against production (nvidia/nemotron-3.5-embed-1b,
  2048 dimensions), after a full reindex and after pruning points of titles
  that had left the index:

    * `:query` — text query against stored titles. For thirteen relevant
      queries the 10th hit never scored below 0.416 (the best hit at least
      0.477: "astronauta perdido no espaço" → Perdido em Marte 0.536), while
      six off-topic queries ("receita de bolo de chocolate", "declaração do
      imposto de renda"...) topped out at 0.383 on a title-word match. The
      0.25 floor kept for the 3.0 model let every one of those through.
    * `:similar` — one stored title against the others. The 10th neighbour
      scored 0.66 / 0.53 / 0.47 at the 10th percentile for movies, series
      and anime, and a title's 200th neighbour in another collection still
      scores about 0.53; 0.50 keeps real neighbours and drops that tail.
    * `:profile` — a user profile (the mean of watched titles' vectors)
      against titles. A tight synthetic profile (a title and its five
      neighbours) kept its 30th hit at 0.67 or more; real profiles mix
      tastes and score lower, so the floor sits below `:similar`.

  The 2026-10-19 floors for nemotron-3-embed-1b were 0.25 / 0.40 / 0.35.

  Re-measure and update these when the embedding model changes. They can be
  overridden without a code change through
  `config :streamix, :semantic_scores, query: …, similar: …, profile: …`.
  """

  @defaults [query: 0.40, similar: 0.50, profile: 0.45]

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
