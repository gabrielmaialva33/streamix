defmodule Streamix.AI do
  @moduledoc """
  Public facade for semantic search and user personalization.

  Web callers use this module so internal AI providers and orchestration
  modules can evolve without leaking through the context boundary.
  """

  alias Streamix.AI.{SemanticSearch, UserAnalytics}

  # Semantic search
  defdelegate semantic_search_status(), to: Streamix.AI.SearchHealth, as: :status
  defdelegate semantic_search_available?(), to: SemanticSearch, as: :available?
  defdelegate semantic_search(query, collection, opts \\ []), to: SemanticSearch, as: :search

  defdelegate similar_content(content_id, collection, opts \\ []),
    to: SemanticSearch,
    as: :similar

  defdelegate semantic_search_stats(), to: SemanticSearch, as: :stats
  defdelegate semantic_search_info(), to: SemanticSearch, as: :info
  defdelegate ensure_vector_collections(), to: SemanticSearch, as: :bootstrap_collections

  # Personalization — every per-user function takes the user's unlocked
  # Streamix.Library.Key (scope.library_key), never a bare user id.
  defdelegate compute_user_profile(key), to: UserAnalytics
  defdelegate get_user_profile(key), to: UserAnalytics
  defdelegate get_personalization_context(key), to: UserAnalytics
  defdelegate get_user_insights(key), to: UserAnalytics
  defdelegate get_recommendations(key, opts \\ []), to: UserAnalytics
  defdelegate get_channel_recommendations(key, opts \\ []), to: UserAnalytics
  defdelegate get_similar_to(content_id, collection, opts \\ []), to: UserAnalytics
  defdelegate get_personalized_trending(key, opts \\ []), to: UserAnalytics
  defdelegate get_personalized_series(key, opts \\ []), to: UserAnalytics
  defdelegate get_personalized_channels(key, opts \\ []), to: UserAnalytics
  defdelegate get_user_genre_filters(key), to: UserAnalytics
  defdelegate get_period_filters(), to: UserAnalytics
  defdelegate get_channel_category_filters(), to: UserAnalytics
end
