defmodule StreamixWeb.Api.V1.OpenApi do
  @moduledoc "OpenAPI document for the external Streamix v1 HTTP contract."

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{
    Components,
    Contact,
    Info,
    License,
    OpenApi,
    Paths,
    SecurityScheme,
    Server,
    Tag
  }

  alias StreamixWeb.Api.V1.Schemas

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Streamix Catalog API",
        version: "1.0.0",
        description: """
        Provider-aware TV/mobile API for public catalog discovery and signed playback.

        Success responses use a `data` envelope. Collection metadata, applied
        filters and pagination live under `meta`; failures use the stable
        `{\"error\": {\"code\": ..., \"message\": ...}}` envelope.
        """,
        contact: %Contact{
          name: "Streamix maintainers",
          url: "https://github.com/gabrielmaialva33/streamix/issues"
        },
        license: %License{
          name: "MIT",
          url: "https://github.com/gabrielmaialva33/streamix/blob/master/LICENSE"
        }
      },
      servers: [%Server{url: "/", description: "Current origin"}],
      paths: Paths.from_router(StreamixWeb.Router),
      components: %Components{
        schemas: Schemas.schemas(),
        securitySchemes: %{
          "ApiKeyAuth" => %SecurityScheme{
            type: "apiKey",
            in: "header",
            name: "X-API-Key",
            description: "Integration key configured through API_KEYS"
          }
        }
      },
      security: [%{"ApiKeyAuth" => []}],
      tags: [
        %Tag{
          name: "Catalog",
          description: "Provider-aware public catalog, discovery and playback URLs"
        }
      ]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
