defmodule StreamixWeb.Api.V1.Schemas.Common do
  @moduledoc false

  alias OpenApiSpex.{Reference, Schema}

  @provider_types ["xtream", "gindex", "torrent"]
  @content_types ["channels", "movies", "series"]

  def schemas do
    %{
      "ApiError" =>
        object(
          "ApiError",
          %{
            code: string(description: "Stable machine-readable error code"),
            message: string(description: "Human-readable error message"),
            retry_after:
              integer(
                minimum: 0,
                description: "Seconds before retrying a rate-limited request"
              )
          },
          [:code, :message],
          example: %{
            "code" => "invalid_provider_type",
            "message" => "Provider type must be xtream, gindex, or torrent"
          }
        ),
      "ApiErrorResponse" =>
        object(
          "ApiErrorResponse",
          %{error: ref("ApiError")},
          [:error],
          description: "Stable error envelope returned by the v1 API"
        ),
      "ProviderRef" =>
        object(
          "ProviderRef",
          %{
            id: id("Public provider identifier"),
            name: string(min_length: 1, description: "Display name"),
            type: string(enum: @provider_types, description: "Provider adapter")
          },
          [:id, :name, :type],
          example: %{"id" => 4, "name" => "Streamix Fallback", "type" => "xtream"}
        ),
      "CatalogCounts" =>
        object(
          "CatalogCounts",
          %{
            channels: count("Synchronized live-channel rows"),
            movies: count("Synchronized movie rows"),
            series: count("Synchronized series rows")
          },
          [:channels, :movies, :series]
        ),
      "CatalogProvider" =>
        object(
          "CatalogProvider",
          %{
            id: id("Public provider identifier"),
            name: string(min_length: 1, description: "Display name"),
            type: string(enum: @provider_types, description: "Provider adapter"),
            content_types:
              array(
                string(enum: @content_types),
                description: "Catalog resources supported by this adapter",
                unique_items: true
              ),
            catalog_counts: ref("CatalogCounts")
          },
          [:id, :name, :type, :content_types, :catalog_counts]
        ),
      "CatalogProvidersResponse" =>
        object(
          "CatalogProvidersResponse",
          %{
            data: array(ref("CatalogProvider")),
            meta: ref("CollectionTotalMeta")
          },
          [:data, :meta]
        ),
      "CollectionTotalMeta" =>
        object(
          "CollectionTotalMeta",
          %{total: count("Number of resources in this response")},
          [:total]
        ),
      "StreamData" =>
        object(
          "StreamData",
          %{
            stream_url:
              string(format: :uri, description: "Short-lived signed Streamix playback URL")
          },
          [:stream_url]
        ),
      "StreamResponse" =>
        object(
          "StreamResponse",
          %{data: ref("StreamData")},
          [:data]
        )
    }
  end

  def ref(name) when is_binary(name),
    do: %Reference{"$ref": "#/components/schemas/#{name}"}

  def object(title, properties, required, opts \\ []) do
    %Schema{
      title: title,
      type: :object,
      description: opts[:description],
      properties: properties,
      required: required,
      additionalProperties: Keyword.get(opts, :additional_properties, false),
      example: opts[:example]
    }
  end

  def array(items, opts \\ []) do
    %Schema{
      type: :array,
      items: items,
      description: opts[:description],
      minItems: opts[:min_items],
      maxItems: opts[:max_items],
      uniqueItems: opts[:unique_items]
    }
  end

  def id(description \\ "Resource identifier") do
    integer(minimum: 1, format: :int64, description: description)
  end

  def count(description \\ nil) do
    integer(minimum: 0, format: :int64, description: description)
  end

  def integer(opts \\ []) do
    %Schema{
      type: :integer,
      format: opts[:format],
      minimum: opts[:minimum],
      maximum: opts[:maximum],
      nullable: opts[:nullable],
      description: opts[:description],
      default: opts[:default],
      enum: opts[:enum]
    }
  end

  def number(opts \\ []) do
    %Schema{
      type: :number,
      format: opts[:format],
      minimum: opts[:minimum],
      maximum: opts[:maximum],
      nullable: opts[:nullable],
      description: opts[:description]
    }
  end

  def boolean(opts \\ []) do
    %Schema{
      type: :boolean,
      nullable: opts[:nullable],
      description: opts[:description],
      default: opts[:default]
    }
  end

  def string(opts \\ []) do
    %Schema{
      type: :string,
      format: opts[:format],
      minLength: opts[:min_length],
      maxLength: opts[:max_length],
      pattern: opts[:pattern],
      nullable: opts[:nullable],
      description: opts[:description],
      default: opts[:default],
      enum: opts[:enum]
    }
  end
end
