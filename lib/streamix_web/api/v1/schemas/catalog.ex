defmodule StreamixWeb.Api.V1.Schemas.Catalog do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias StreamixWeb.Api.V1.Schemas.Common

  @provider_types ["xtream", "gindex", "torrent"]
  @sorts ["rating_desc", "created_desc", "year_desc", "name_asc"]
  @category_types ["live", "vod", "series"]
  @content_types ["movie", "series"]

  def schemas do
    movie_card = movie_card_properties()
    series_card = series_card_properties()
    channel_card = channel_card_properties()

    %{
      "CatalogPagination" =>
        Common.object(
          "CatalogPagination",
          %{
            limit: Common.integer(minimum: 1, maximum: 100),
            offset: Common.integer(minimum: 0, maximum: 100_000),
            total: Common.count("Canonical resources matching the filters"),
            has_more: Common.boolean(description: "Whether another page exists"),
            next_offset:
              Common.integer(
                minimum: 0,
                maximum: 100_000,
                nullable: true,
                description: "Offset for the next request, or null on the final page"
              )
          },
          [:limit, :offset, :total, :has_more, :next_offset]
        ),
      "CatalogContentFilters" =>
        Common.object(
          "CatalogContentFilters",
          %{
            provider_id: nullable_id("Exact public provider filter"),
            provider_type:
              Common.string(
                enum: @provider_types,
                nullable: true,
                description: "Provider adapter filter"
              ),
            category_id: nullable_id("Provider-scoped category filter"),
            search: Common.string(nullable: true, max_length: 200),
            sort: Common.string(enum: @sorts, nullable: true)
          },
          [:provider_id, :provider_type, :category_id, :search, :sort]
        ),
      "CatalogProviderFilters" =>
        Common.object(
          "CatalogProviderFilters",
          %{
            provider_id: nullable_id("Exact public provider filter"),
            provider_type:
              Common.string(
                enum: @provider_types,
                nullable: true,
                description: "Provider adapter filter"
              )
          },
          [:provider_id, :provider_type]
        ),
      "CatalogPageMeta" =>
        Common.object(
          "CatalogPageMeta",
          %{
            pagination: Common.ref("CatalogPagination"),
            filters: Common.ref("CatalogContentFilters")
          },
          [:pagination, :filters]
        ),
      "MovieCard" =>
        Common.object(
          "MovieCard",
          movie_card,
          Map.keys(movie_card),
          example: %{
            "id" => 101,
            "name" => "Dune Part Two 4K",
            "title" => "Dune: Part Two",
            "year" => 2024,
            "rating" => 8.6,
            "genre" => "Science Fiction, Adventure",
            "poster" => "https://img.example.test/dune.jpg",
            "duration" => "2h 46min",
            "provider" => %{"id" => 4, "name" => "Streamix Fallback", "type" => "xtream"}
          }
        ),
      "SeriesCard" => Common.object("SeriesCard", series_card, Map.keys(series_card)),
      "ChannelCard" => Common.object("ChannelCard", channel_card, Map.keys(channel_card)),
      "MoviesPageResponse" => page_response("MoviesPageResponse", "MovieCard"),
      "SeriesPageResponse" => page_response("SeriesPageResponse", "SeriesCard"),
      "ChannelsPageResponse" => page_response("ChannelsPageResponse", "ChannelCard"),
      "CatalogCategory" =>
        Common.object(
          "CatalogCategory",
          %{
            id: Common.id(),
            name: Common.string(min_length: 1),
            type: Common.string(enum: @category_types),
            provider: Common.ref("ProviderRef")
          },
          [:id, :name, :type, :provider]
        ),
      "CatalogCategoryFilters" =>
        Common.object(
          "CatalogCategoryFilters",
          %{
            provider_id: nullable_id("Exact public provider filter"),
            provider_type: Common.string(enum: @provider_types, nullable: true),
            type: Common.string(enum: @category_types)
          },
          [:provider_id, :provider_type, :type]
        ),
      "CatalogCategoriesMeta" =>
        Common.object(
          "CatalogCategoriesMeta",
          %{
            total: Common.count(),
            filters: Common.ref("CatalogCategoryFilters")
          },
          [:total, :filters]
        ),
      "CatalogCategoriesResponse" =>
        Common.object(
          "CatalogCategoriesResponse",
          %{
            data: Common.array(Common.ref("CatalogCategory")),
            meta: Common.ref("CatalogCategoriesMeta")
          },
          [:data, :meta]
        ),
      "PublicCatalogCounts" =>
        Common.object(
          "PublicCatalogCounts",
          %{
            channels_count: Common.count(),
            movies_count: Common.count(),
            series_count: Common.count()
          },
          [:channels_count, :movies_count, :series_count]
        ),
      "FeaturedContent" => featured_content(),
      "FeaturedMeta" =>
        Common.object(
          "FeaturedMeta",
          %{
            catalog_counts: Common.ref("PublicCatalogCounts"),
            filters: Common.ref("CatalogProviderFilters")
          },
          [:catalog_counts, :filters]
        ),
      "FeaturedResponse" =>
        Common.object(
          "FeaturedResponse",
          %{data: nullable_ref("FeaturedContent"), meta: Common.ref("FeaturedMeta")},
          [:data, :meta]
        ),
      "MovieDetail" => movie_detail(),
      "MovieDetailResponse" => resource_response("MovieDetailResponse", "MovieDetail"),
      "EpisodeSummary" => episode_summary(),
      "Season" => season(),
      "SeriesDetail" => series_detail(),
      "SeriesDetailResponse" => resource_response("SeriesDetailResponse", "SeriesDetail"),
      "EpisodeDetail" => episode_detail(),
      "EpisodeDetailResponse" => resource_response("EpisodeDetailResponse", "EpisodeDetail"),
      "ChannelDetail" => channel_detail(),
      "ChannelDetailResponse" => resource_response("ChannelDetailResponse", "ChannelDetail"),
      "RankedMovieCard" =>
        Common.object(
          "RankedMovieCard",
          Map.put(movie_card, :score, rank_score()),
          [:score | Map.keys(movie_card)]
        ),
      "RankedSeriesCard" =>
        Common.object(
          "RankedSeriesCard",
          Map.put(series_card, :score, rank_score()),
          [:score | Map.keys(series_card)]
        ),
      "RankedChannelCard" =>
        Common.object(
          "RankedChannelCard",
          Map.put(channel_card, :score, rank_score()),
          [:score | Map.keys(channel_card)]
        ),
      "CatalogSearchData" => search_data(),
      "CatalogSearchMeta" => search_meta(),
      "CatalogSearchResponse" =>
        Common.object(
          "CatalogSearchResponse",
          %{data: Common.ref("CatalogSearchData"), meta: Common.ref("CatalogSearchMeta")},
          [:data, :meta]
        ),
      "CatalogSuggestion" => suggestion(),
      "CatalogSuggestMeta" => suggest_meta(),
      "CatalogSuggestResponse" =>
        Common.object(
          "CatalogSuggestResponse",
          %{
            data: Common.array(Common.ref("CatalogSuggestion")),
            meta: Common.ref("CatalogSuggestMeta")
          },
          [:data, :meta]
        ),
      "CatalogHomeData" => home_data(),
      "CatalogHomeMeta" =>
        Common.object(
          "CatalogHomeMeta",
          %{
            limit_per_section: Common.integer(minimum: 1, maximum: 50),
            filters: Common.ref("CatalogProviderFilters")
          },
          [:limit_per_section, :filters]
        ),
      "CatalogHomeResponse" =>
        Common.object(
          "CatalogHomeResponse",
          %{data: Common.ref("CatalogHomeData"), meta: Common.ref("CatalogHomeMeta")},
          [:data, :meta]
        ),
      "CatalogShelfMeta" => shelf_meta(),
      "CatalogShelfResponse" => shelf_response()
    }
  end

  def movies_parameters, do: page_parameters(20) ++ content_filter_parameters(include_sort?: true)
  def featured_parameters, do: provider_parameters()
  def series_parameters, do: movies_parameters()

  def channels_parameters,
    do: page_parameters(30) ++ content_filter_parameters(include_sort?: false)

  def categories_parameters do
    [
      type: [
        in: :query,
        schema: Common.string(enum: @category_types, default: "vod"),
        description: "Category kind (movies use vod)"
      ]
    ] ++ provider_parameters()
  end

  def search_parameters do
    [
      q: [
        in: :query,
        schema: Common.string(max_length: 200),
        description: "Query; at least two characters returns matches"
      ],
      limit: [
        in: :query,
        schema: Common.integer(minimum: 1, maximum: 20, default: 10),
        description: "Maximum results per content type"
      ]
    ] ++ provider_parameters()
  end

  def suggest_parameters do
    [
      q: [
        in: :query,
        schema: Common.string(max_length: 100),
        description: "Typeahead query"
      ],
      limit: [
        in: :query,
        schema: Common.integer(minimum: 1, maximum: 20, default: 10)
      ]
    ] ++ provider_parameters()
  end

  def home_parameters do
    [
      limit: [
        in: :query,
        schema: Common.integer(minimum: 1, maximum: 50, default: 20),
        description: "Maximum cards per home section"
      ]
    ] ++ provider_parameters()
  end

  def shelf_parameters do
    [
      type: [
        in: :query,
        schema: Common.string(enum: @content_types, default: "movie"),
        description: "Shelf content type"
      ],
      limit: [
        in: :query,
        schema: Common.integer(minimum: 1, maximum: 50, default: 20)
      ]
    ] ++ provider_parameters()
  end

  def id_parameter(resource) do
    [
      id: [
        in: :path,
        schema: Common.id("#{resource} identifier"),
        required: true,
        description: "#{resource} identifier"
      ]
    ]
  end

  defp movie_card_properties do
    %{
      id: Common.id(),
      name: Common.string(min_length: 1),
      title: Common.string(nullable: true),
      year: year(),
      rating: rating(),
      genre: Common.string(nullable: true),
      poster: Common.string(nullable: true),
      duration: Common.string(nullable: true),
      provider: Common.ref("ProviderRef")
    }
  end

  defp series_card_properties do
    movie_card_properties()
    |> Map.delete(:duration)
  end

  defp channel_card_properties do
    %{
      id: Common.id(),
      name: Common.string(min_length: 1),
      icon: Common.string(nullable: true),
      provider: Common.ref("ProviderRef")
    }
  end

  defp featured_content do
    properties = %{
      id: Common.id(),
      type: Common.string(enum: @content_types),
      title: Common.string(min_length: 1),
      name: Common.string(min_length: 1),
      year: year(),
      rating: rating(),
      genre: Common.string(nullable: true),
      plot: Common.string(nullable: true),
      poster: Common.string(nullable: true),
      backdrop: Common.array(Common.string()),
      provider: Common.ref("ProviderRef")
    }

    Common.object(
      "FeaturedContent",
      Map.merge(properties, image_variant_properties()),
      Map.keys(properties)
    )
  end

  defp movie_detail do
    properties =
      movie_card_properties()
      |> Map.merge(%{
        plot: Common.string(nullable: true),
        cast: Common.string(nullable: true),
        director: Common.string(nullable: true),
        content_rating: Common.string(nullable: true),
        tagline: Common.string(nullable: true),
        backdrop: Common.array(Common.string()),
        youtube_trailer: Common.string(nullable: true),
        stream_url: Common.string(format: :uri),
        browser_stream_url: Common.string(format: :uri)
      })
      |> Map.merge(image_variant_properties())

    optional = Map.keys(image_variant_properties())
    Common.object("MovieDetail", properties, Map.keys(properties) -- optional)
  end

  defp episode_summary do
    Common.object(
      "EpisodeSummary",
      %{
        id: Common.id(),
        title: Common.string(nullable: true),
        tmdb_title: Common.string(nullable: true),
        episode_num: Common.integer(minimum: 0),
        plot: Common.string(nullable: true),
        still: Common.string(nullable: true),
        duration: Common.string(nullable: true),
        air_date: Common.string(format: :date, nullable: true)
      },
      [:id, :title, :tmdb_title, :episode_num, :plot, :still, :duration, :air_date]
    )
  end

  defp season do
    Common.object(
      "Season",
      %{
        id: Common.id(),
        name: Common.string(nullable: true),
        season_number: Common.integer(minimum: 0),
        episode_count: Common.count(),
        episodes: Common.array(Common.ref("EpisodeSummary"))
      },
      [:id, :name, :season_number, :episode_count, :episodes]
    )
  end

  defp series_detail do
    properties =
      series_card_properties()
      |> Map.merge(%{
        plot: Common.string(nullable: true),
        cast: Common.string(nullable: true),
        director: Common.string(nullable: true),
        backdrop: Common.array(Common.string()),
        season_count: Common.count(),
        episode_count: Common.count(),
        seasons: Common.array(Common.ref("Season"))
      })
      |> Map.merge(image_variant_properties())

    optional = Map.keys(image_variant_properties())
    Common.object("SeriesDetail", properties, Map.keys(properties) -- optional)
  end

  defp episode_detail do
    properties = %{
      id: Common.id(),
      title: Common.string(nullable: true),
      tmdb_title: Common.string(nullable: true),
      episode_num: Common.integer(minimum: 0),
      season_number: Common.integer(minimum: 1),
      plot: Common.string(nullable: true),
      still: Common.string(nullable: true),
      duration: Common.string(nullable: true),
      air_date: Common.string(format: :date, nullable: true),
      series_id: Common.id(),
      series_name: Common.string(min_length: 1),
      stream_url: Common.string(format: :uri),
      browser_stream_url: Common.string(format: :uri),
      provider: Common.ref("ProviderRef")
    }

    Common.object("EpisodeDetail", properties, Map.keys(properties))
  end

  defp channel_detail do
    properties =
      channel_card_properties()
      |> Map.merge(%{
        stream_url: Common.string(format: :uri),
        browser_stream_url: Common.string(format: :uri)
      })

    Common.object("ChannelDetail", properties, Map.keys(properties))
  end

  defp search_data do
    Common.object(
      "CatalogSearchData",
      %{
        movies: Common.array(Common.ref("RankedMovieCard")),
        series: Common.array(Common.ref("RankedSeriesCard")),
        channels: Common.array(Common.ref("RankedChannelCard"))
      },
      [:movies, :series, :channels]
    )
  end

  defp search_meta do
    Common.object(
      "CatalogSearchMeta",
      %{
        query: Common.string(max_length: 200),
        limit_per_type: Common.integer(minimum: 1, maximum: 20),
        filters: Common.ref("CatalogProviderFilters")
      },
      [:query, :limit_per_type, :filters]
    )
  end

  defp suggestion do
    Common.object(
      "CatalogSuggestion",
      %{
        id: Common.id(),
        type: Common.string(enum: ["movie", "series", "channel"]),
        title: Common.string(min_length: 1),
        year: year(),
        poster: Common.string(nullable: true),
        score: rank_score(),
        provider: Common.ref("ProviderRef")
      },
      [:id, :type, :title, :poster, :score, :provider]
    )
  end

  defp suggest_meta do
    Common.object(
      "CatalogSuggestMeta",
      %{
        query: Common.string(max_length: 100),
        limit: Common.integer(minimum: 1, maximum: 20),
        filters: Common.ref("CatalogProviderFilters")
      },
      [:query, :limit, :filters]
    )
  end

  defp home_data do
    Common.object(
      "CatalogHomeData",
      %{
        featured: nullable_ref("FeaturedContent"),
        trending_movies: Common.array(Common.ref("MovieCard")),
        recent_movies: Common.array(Common.ref("MovieCard")),
        top_rated_movies: Common.array(Common.ref("MovieCard")),
        trending_series: Common.array(Common.ref("SeriesCard"))
      },
      [:featured, :trending_movies, :recent_movies, :top_rated_movies, :trending_series]
    )
  end

  defp shelf_meta do
    Common.object(
      "CatalogShelfMeta",
      %{
        type: Common.string(enum: @content_types),
        limit: Common.integer(minimum: 1, maximum: 50),
        filters: Common.ref("CatalogProviderFilters")
      },
      [:type, :limit, :filters]
    )
  end

  defp shelf_response do
    item = %Schema{oneOf: [Common.ref("MovieCard"), Common.ref("SeriesCard")]}

    Common.object(
      "CatalogShelfResponse",
      %{data: Common.array(item), meta: Common.ref("CatalogShelfMeta")},
      [:data, :meta]
    )
  end

  defp page_response(title, item_schema) do
    Common.object(
      title,
      %{data: Common.array(Common.ref(item_schema)), meta: Common.ref("CatalogPageMeta")},
      [:data, :meta]
    )
  end

  defp resource_response(title, resource_schema) do
    Common.object(title, %{data: Common.ref(resource_schema)}, [:data])
  end

  defp image_variant_properties do
    %{
      poster_w240: Common.string(format: :uri),
      poster_w480: Common.string(format: :uri),
      poster_w720: Common.string(format: :uri),
      backdrop_w720: Common.string(format: :uri),
      backdrop_w1280: Common.string(format: :uri)
    }
  end

  defp nullable_ref(name),
    do: %Schema{type: :object, allOf: [Common.ref(name)], nullable: true}

  defp nullable_id(description),
    do: Common.integer(minimum: 1, format: :int64, nullable: true, description: description)

  defp year, do: Common.integer(minimum: 0, maximum: 2200, nullable: true)
  defp rating, do: Common.number(format: :float, minimum: 0, maximum: 10, nullable: true)
  defp rank_score, do: Common.integer(minimum: 0, description: "Search relevance score")

  defp page_parameters(default_limit) do
    [
      limit: [
        in: :query,
        schema: Common.integer(minimum: 1, maximum: 100, default: default_limit),
        description: "Page size"
      ],
      offset: [
        in: :query,
        schema: Common.integer(minimum: 0, maximum: 100_000, default: 0),
        description: "Number of canonical resources to skip"
      ]
    ]
  end

  defp content_filter_parameters(opts) do
    sort =
      if opts[:include_sort?] do
        [
          sort: [
            in: :query,
            schema: Common.string(enum: @sorts),
            description: "Stable result ordering"
          ]
        ]
      else
        []
      end

    provider_parameters() ++
      [
        category_id: [
          in: :query,
          schema: Common.id("Provider-scoped category identifier"),
          description: "Provider-scoped category identifier"
        ],
        search: [in: :query, type: :string, description: "Case-insensitive title filter"]
      ] ++ sort
  end

  defp provider_parameters do
    [
      provider_id: [
        in: :query,
        schema: Common.id("Exact public provider identifier"),
        description: "Restrict results to one public provider"
      ],
      provider_type: [
        in: :query,
        schema: Common.string(enum: @provider_types),
        description: "Restrict results to one provider adapter"
      ]
    ]
  end
end
