defmodule Streamix.AI.UserAnalytics do
  @moduledoc """
  AI-powered user analytics and personalized recommendations.

  Uses watch history + TMDB metadata + embeddings to create
  personalized content recommendations for each user.

  ## Features

  - **User Taste Profile**: Aggregated vector from watched content
  - **Personalized Recommendations**: "For You" based on watch history
  - **Similar Content**: "Because you watched X"
  - **Channel Affinity**: Recommended live channels
  - **Time-based Patterns**: "You like action on weekends"

  ## Architecture

  1. User watches content -> sealed WatchProgress saved (see Streamix.Library)
  2. Background job generates embedding for content
  3. User profile vector = weighted average of watched content vectors,
     computed inside the user's session with their library key
  4. Recommendations = Qdrant search using profile vector

  Everything derived from the history takes the user's `Streamix.Library.Key`
  and lives only in this node's memory (`Streamix.Cache.fetch_personal/4`):
  no taste vector, insight or recommendation list is written to Qdrant,
  Redis or the database.
  """

  alias Streamix.AI.UserAnalytics.Channels
  alias Streamix.AI.UserAnalytics.Context
  alias Streamix.AI.UserAnalytics.Filters
  alias Streamix.AI.UserAnalytics.Indexing
  alias Streamix.AI.UserAnalytics.Insights
  alias Streamix.AI.UserAnalytics.PersonalizedContent
  alias Streamix.AI.UserAnalytics.Profile
  alias Streamix.AI.UserAnalytics.Recommendations

  defdelegate compute_user_profile(key), to: Profile
  defdelegate get_user_profile(key), to: Profile
  defdelegate get_personalization_context(key), to: Context, as: :load

  defdelegate get_recommendations(key, opts \\ []), to: Recommendations
  defdelegate get_similar_to(content_id, collection, opts \\ []), to: Recommendations
  defdelegate get_more_like_this(content, collection), to: Recommendations

  defdelegate get_channel_recommendations(key, opts \\ []), to: Channels
  defdelegate get_personalized_channels(key, opts \\ []), to: Channels

  defdelegate get_personalized_trending(key, opts \\ []), to: PersonalizedContent
  defdelegate get_personalized_series(key, opts \\ []), to: PersonalizedContent

  defdelegate get_user_genre_filters(key), to: Filters
  defdelegate get_period_filters(), to: Filters
  defdelegate get_channel_category_filters(), to: Filters

  defdelegate get_user_insights(key), to: Insights

  defdelegate index_content(content, collection), to: Indexing
  defdelegate index_contents(contents, collection), to: Indexing
end
