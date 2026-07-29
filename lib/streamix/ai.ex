defmodule Streamix.AI do
  @moduledoc """
  Public facade for semantic search and user personalization.

  Web callers use this module so internal AI providers and orchestration
  modules can evolve without leaking through the context boundary.
  """

  alias Streamix.AI.{SemanticSearch, UserAnalytics}

  # Semantic search
  defdelegate semantic_search_available?(), to: SemanticSearch, as: :available?
  defdelegate semantic_search(query, collection, opts \\ []), to: SemanticSearch, as: :search

  defdelegate similar_content(content_id, collection, opts \\ []),
    to: SemanticSearch,
    as: :similar

  defdelegate semantic_search_stats(), to: SemanticSearch, as: :stats
  defdelegate semantic_search_info(), to: SemanticSearch, as: :info

  # Personalization
  defdelegate compute_user_profile(user_id), to: UserAnalytics
  defdelegate get_user_profile(user_id), to: UserAnalytics
  defdelegate get_user_insights(user_id), to: UserAnalytics
  defdelegate get_recommendations(user_id, opts \\ []), to: UserAnalytics
  defdelegate get_channel_recommendations(user_id, opts \\ []), to: UserAnalytics
  defdelegate get_similar_to(content_id, collection, opts \\ []), to: UserAnalytics
  defdelegate get_personalized_trending(user_id, opts \\ []), to: UserAnalytics
  defdelegate get_personalized_series(user_id, opts \\ []), to: UserAnalytics
  defdelegate get_personalized_channels(user_id, opts \\ []), to: UserAnalytics
  defdelegate get_user_genre_filters(user_id), to: UserAnalytics
  defdelegate get_period_filters(), to: UserAnalytics
  defdelegate get_channel_category_filters(), to: UserAnalytics
end
