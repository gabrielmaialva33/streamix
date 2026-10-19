defmodule StreamixWeb.Api.V1.Schemas.Reels do
  @moduledoc false

  alias StreamixWeb.Api.V1.Schemas.{Catalog, Common}

  @max_category_length 100
  @max_page 1000
  @max_per_page 100
  @default_per_page 24

  def schemas do
    reel_card =
      Map.put(
        Catalog.series_card_properties(),
        :reel_category,
        Common.string(
          min_length: 1,
          description:
            "Reel category display name; the requested category when filtering, otherwise " <>
              "one category the title belongs to"
        )
      )

    %{
      "ReelCard" =>
        Common.object("ReelCard", reel_card, Map.keys(reel_card),
          description:
            "Series card for a vertical short drama. Open it with GET /api/v1/catalog/series/{id}.",
          example: %{
            "id" => 7_301_442,
            "name" => "Amor Escondido em Seul",
            "title" => nil,
            "year" => 2025,
            "rating" => nil,
            "genre" => nil,
            "poster" => "https://img.example.test/reels/amor-escondido.jpg",
            "provider" => %{"id" => 9, "name" => "MegaEmbed", "type" => "xtream"},
            "reel_category" => "Histórias da Ásia"
          }
        ),
      "ReelsPagination" =>
        Common.object(
          "ReelsPagination",
          %{
            page: Common.integer(minimum: 1, maximum: @max_page),
            per_page: Common.integer(minimum: 1, maximum: @max_per_page),
            total: Common.count("Canonical short dramas matching the filters"),
            has_more: Common.boolean(description: "Whether another page exists"),
            next_page:
              Common.integer(
                minimum: 2,
                maximum: @max_page,
                nullable: true,
                description: "Page for the next request, or null on the final page"
              )
          },
          [:page, :per_page, :total, :has_more, :next_page]
        ),
      "ReelsFilters" =>
        Common.object(
          "ReelsFilters",
          %{
            category:
              Common.string(
                nullable: true,
                max_length: @max_category_length,
                description: "Applied reel category, or null for every category"
              )
          },
          [:category]
        ),
      "ReelsPageMeta" =>
        Common.object(
          "ReelsPageMeta",
          %{
            pagination: Common.ref("ReelsPagination"),
            filters: Common.ref("ReelsFilters")
          },
          [:pagination, :filters]
        ),
      "ReelsPageResponse" =>
        Common.object(
          "ReelsPageResponse",
          %{data: Common.array(Common.ref("ReelCard")), meta: Common.ref("ReelsPageMeta")},
          [:data, :meta]
        ),
      "ReelCategory" =>
        Common.object(
          "ReelCategory",
          %{
            name:
              Common.string(
                min_length: 1,
                description: "Display name without the provider's `[Reels] ` prefix"
              ),
            count: Common.count("Canonical short dramas in this category")
          },
          [:name, :count],
          example: %{"name" => "Histórias da Ásia", "count" => 383}
        ),
      "ReelCategoriesResponse" =>
        Common.object(
          "ReelCategoriesResponse",
          %{
            data:
              Common.array(Common.ref("ReelCategory"),
                description: "Merged across public providers, largest first"
              ),
            meta: Common.ref("CollectionTotalMeta")
          },
          [:data, :meta]
        )
    }
  end

  def list_parameters do
    [
      category: [
        in: :query,
        schema: Common.string(max_length: @max_category_length),
        description:
          "Reel category display name from GET /api/v1/catalog/reels/categories; " <>
            "empty or absent lists every category"
      ],
      page: [
        in: :query,
        schema: Common.integer(minimum: 1, maximum: @max_page, default: 1),
        description: "1-based page number"
      ],
      per_page: [
        in: :query,
        schema: Common.integer(minimum: 1, maximum: @max_per_page, default: @default_per_page),
        description: "Page size"
      ]
    ]
  end
end
