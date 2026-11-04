defmodule StreamixWeb.Api.V1.Schemas.Resources do
  @moduledoc "Schemas for the existing non-catalog API payloads."

  import StreamixWeb.Api.V1.Schemas.Common

  alias OpenApiSpex.Schema

  def schemas do
    [auth(), library(), providers(), discovery(), playback()]
    |> Enum.reduce(&Map.merge/2)
  end

  defp auth do
    %{
      "AuthCredentials" =>
        object("AuthCredentials", %{email: string(), password: string(), name: string()}, [
          :email,
          :password
        ]),
      "AuthUser" =>
        object(
          "AuthUser",
          %{id: id(), email: string(), name: string(nullable: true), role: string()},
          [:id, :email, :name, :role]
        ),
      "AuthTokenResponse" =>
        object("AuthTokenResponse", %{token: string(), user: ref("AuthUser")}, [:token, :user]),
      "AuthUserResponse" => object("AuthUserResponse", %{user: ref("AuthUser")}, [:user])
    }
  end

  defp library do
    target = %{type: string(enum: ~w(movie series episode live_channel)), content_id: id()}

    history = %{
      id: id(),
      content_type: string(nullable: true),
      content_id: integer(nullable: true),
      progress_seconds: count(),
      duration_seconds: integer(nullable: true),
      completed: boolean(),
      watched_at: timestamp()
    }

    %{
      "FavoriteTarget" => object("FavoriteTarget", target, [:type, :content_id]),
      "Favorite" =>
        object(
          "Favorite",
          %{
            content_type: string(),
            content_id: id(),
            content_name: string(nullable: true),
            content_icon: string(nullable: true),
            created_at: timestamp()
          },
          [:content_type, :content_id, :content_name, :content_icon, :created_at]
        ),
      "FavoritesResponse" =>
        object("FavoritesResponse", %{favorites: array(ref("Favorite"))}, [:favorites]),
      "FavoriteCreatedResponse" =>
        object(
          "FavoriteCreatedResponse",
          %{
            data:
              object(nil, %{content_type: string(), content_id: id()}, [
                :content_type,
                :content_id
              ]),
            meta: object(nil, %{version: string(enum: ["v1"])}, [:version])
          },
          [:data, :meta]
        ),
      "FavoriteToggleResponse" =>
        object("FavoriteToggleResponse", %{status: string(enum: ["added", "removed"])}, [:status]),
      "FavoriteSyncRequest" =>
        object(
          "FavoriteSyncRequest",
          %{
            operations:
              array(
                object(
                  nil,
                  Map.merge(target, %{action: string(enum: ["add", "remove"]), at: timestamp()}),
                  [:type, :content_id, :action]
                ),
                max_items: 500
              )
          },
          [:operations]
        ),
      "FavoriteSyncResponse" =>
        object("FavoriteSyncResponse", %{added: count(), removed: count(), skipped: count()}, [
          :added,
          :removed,
          :skipped
        ]),
      "HistoryRequest" =>
        object(
          "HistoryRequest",
          Map.merge(target, %{
            progress_seconds: count(),
            duration_seconds: count(),
            completed: boolean()
          }),
          [:type, :content_id]
        ),
      "HistoryEntry" =>
        object("HistoryEntry", history, [
          :id,
          :content_type,
          :content_id,
          :progress_seconds,
          :duration_seconds,
          :completed
        ]),
      "HistoryResponse" =>
        object("HistoryResponse", %{items: array(ref("HistoryEntry"))}, [:items])
    }
  end

  defp providers do
    %{
      "ProviderRequest" =>
        object(
          "ProviderRequest",
          %{name: string(), url: string(format: :uri), username: string(), password: string()},
          [:name, :url, :username, :password]
        ),
      "PersonalProvider" =>
        object(
          "PersonalProvider",
          %{
            id: id(),
            name: string(),
            url: string(nullable: true),
            provider_type: string(),
            is_active: boolean(),
            last_synced_at: timestamp(),
            channels_count: count(),
            movies_count: count(),
            series_count: count(),
            inserted_at: timestamp()
          },
          [
            :id,
            :name,
            :url,
            :provider_type,
            :is_active,
            :last_synced_at,
            :channels_count,
            :movies_count,
            :series_count,
            :inserted_at
          ]
        ),
      "PersonalProvidersResponse" =>
        object("PersonalProvidersResponse", %{providers: array(ref("PersonalProvider"))}, [
          :providers
        ]),
      "ProviderSyncResponse" =>
        object(
          "ProviderSyncResponse",
          %{status: string(enum: ["sync_started"]), provider_id: id()},
          [:status, :provider_id]
        ),
      "ProviderHealthResponse" =>
        object(
          "ProviderHealthResponse",
          %{
            overall:
              object(nil, %{status: string(), counts: dictionary(count())}, [:status, :counts]),
            providers:
              array(
                object(nil, %{id: id(), name: string(), status: string()}, [],
                  additional_properties: true
                )
              )
          },
          [:overall, :providers]
        )
    }
  end

  defp discovery do
    card = %{
      id: id(),
      name: string(),
      title: string(nullable: true),
      year: integer(nullable: true),
      rating: number(nullable: true),
      genre: string(nullable: true),
      genres: array(object(nil, %{slug: string(), name: string()}, [:slug, :name])),
      poster: string(nullable: true),
      backdrop: %Schema{anyOf: [string(), array(string())], nullable: true},
      plot: string(nullable: true),
      score: number(nullable: true)
    }

    %{
      "SearchCard" =>
        object("SearchCard", card, [:id, :name, :title, :year, :rating, :genre, :genres, :poster]),
      "MovieSearchResponse" =>
        object(
          "MovieSearchResponse",
          %{movies: array(ref("SearchCard")), query: string(nullable: true), semantic: boolean()},
          [:movies, :query, :semantic]
        ),
      "SeriesSearchResponse" =>
        object(
          "SeriesSearchResponse",
          %{series: array(ref("SearchCard")), query: string(nullable: true), semantic: boolean()},
          [:series, :query, :semantic]
        ),
      "SimilarSearchResponse" =>
        object(
          "SimilarSearchResponse",
          %{items: array(ref("SearchCard")), source_id: id(), collection: string()},
          [:items, :source_id, :collection]
        ),
      "SearchStatusResponse" =>
        object(
          "SearchStatusResponse",
          %{
            status: string(),
            available: boolean(),
            stats: dictionary(free_object()),
            reason: string(),
            provider: string(),
            vector_dimensions: count(),
            http_status: integer()
          },
          [:status, :available, :stats]
        ),
      "SearchInfoResponse" =>
        object(
          "SearchInfoResponse",
          %{available: boolean(), embeddings: free_object(), qdrant_enabled: boolean()},
          [:available, :embeddings, :qdrant_enabled]
        ),
      "RecommendationsResponse" =>
        object(
          "RecommendationsResponse",
          %{recommendations: array(ref("SearchCard")), type: string(), personalized: boolean()},
          [:recommendations, :type, :personalized]
        ),
      "SimilarRecommendationsResponse" =>
        object(
          "SimilarRecommendationsResponse",
          %{similar: array(ref("SearchCard")), source_id: id(), type: string()},
          [:similar, :source_id, :type]
        ),
      "RecommendedChannelsResponse" =>
        object(
          "RecommendedChannelsResponse",
          %{
            channels:
              array(
                object(
                  nil,
                  %{
                    id: id(),
                    name: string(),
                    category: string(nullable: true),
                    categories: array(string()),
                    logo: string(nullable: true),
                    provider_id: id()
                  },
                  [:id, :name, :category, :categories, :logo, :provider_id]
                )
              ),
            personalized: boolean()
          },
          [:channels, :personalized]
        ),
      "InsightsResponse" =>
        object(
          "InsightsResponse",
          %{
            insights:
              object(
                nil,
                %{
                  has_data: boolean(),
                  total_items: count(),
                  content_breakdown: free_object(),
                  completion_rate: number(),
                  favorite_genres: array(string()),
                  watch_patterns: free_object(),
                  most_watched_day: string(nullable: true),
                  avg_session_length: number()
                },
                [:has_data]
              )
          },
          [:insights]
        ),
      "ProfileRefreshResponse" =>
        object(
          "ProfileRefreshResponse",
          %{status: string(enum: ["refreshed", "no_history"]), message: string()},
          [:status]
        )
    }
  end

  defp playback do
    program = %{
      id: id(),
      title: string(),
      description: string(nullable: true),
      start: timestamp(),
      end: timestamp(),
      category: string(nullable: true),
      progress: number(minimum: 0, maximum: 1)
    }

    %{
      "EpgProgram" =>
        object("EpgProgram", program, [:title, :description, :start, :end, :category]),
      "EpgProgramsResponse" =>
        object(
          "EpgProgramsResponse",
          %{programs: dictionary(array(ref("EpgProgram"))), fetched_until: timestamp()},
          [:programs, :fetched_until]
        ),
      "EpgNowResponse" =>
        object(
          "EpgNowResponse",
          %{now: dictionary(%Schema{allOf: [ref("EpgProgram")], nullable: true})},
          [:now]
        ),
      "TelemetryRequest" =>
        object(
          "TelemetryRequest",
          %{
            batch_id: string(),
            metrics: array(free_object()),
            events: array(free_object()),
            metric: free_object(),
            event: string(),
            stream_type: string(),
            engine: string(),
            type: string()
          },
          [],
          additional_properties: true,
          description:
            "Accepts metrics/events batches, a metric object, or a single playback event. Unknown metric fields are discarded."
        ),
      "TelemetryResponse" =>
        object("TelemetryResponse", %{accepted: count(), batch_id: string()}, [
          :accepted,
          :batch_id
        ]),
      "MediaTrack" =>
        object(
          "MediaTrack",
          %{
            index: integer(),
            codec: string(nullable: true),
            language: string(),
            title: string(nullable: true),
            channels: integer(nullable: true),
            default: boolean(),
            forced: boolean()
          },
          [:index, :codec, :language, :title, :channels, :default, :forced]
        ),
      "MediaTracksResponse" =>
        object(
          "MediaTracksResponse",
          %{
            audio: array(ref("MediaTrack")),
            subtitle: array(ref("MediaTrack")),
            probed_at: timestamp()
          },
          [:audio, :subtitle, :probed_at]
        ),
      "MediaProbingResponse" =>
        object(
          "MediaProbingResponse",
          %{status: string(enum: ["probing"]), retry_after: count()},
          [:status, :retry_after]
        ),
      "WebVtt" => %Schema{title: "WebVtt", type: :string, description: "WebVTT subtitle text"},
      "ResizedImage" => %Schema{title: "ResizedImage", type: :string, format: :binary}
    }
  end

  defp timestamp, do: string(format: :"date-time", nullable: true)
  defp dictionary(values), do: %Schema{type: :object, additionalProperties: values}
  defp free_object, do: %Schema{type: :object, additionalProperties: true}
end
