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
        Provider-aware TV/mobile API for public catalog discovery and encrypted playback.

        Catalog success responses use a `data` envelope, except `/catalog/games`, which returns a bare array.
        Other resources retain their documented endpoint-specific success payloads. Failures use the stable
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
      paths: paths(),
      components: %Components{
        schemas: Schemas.schemas(),
        securitySchemes: %{
          "BearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "88-character URL-safe base64 session token and library secret",
            description:
              "Opaque credential issued by auth/login or auth/register. Pre-upgrade tokens require a new login."
          },
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

  defp paths do
    paths = Paths.from_router(StreamixWeb.Router)
    {preflight, paths} = Map.pop!(paths, "/api/v1/*path")

    paths
    |> Map.put("/api/v1/{path}", preflight)
    |> Map.put("/api/v1/openapi.json", %OpenApiSpex.PathItem{
      get: %OpenApiSpex.Operation{
        operationId: "documentation.spec",
        summary: "Get this OpenAPI document",
        security: [],
        responses: %{
          "200" => %OpenApiSpex.Response{
            description: "OpenAPI 3 document",
            content: %{
              "application/json" => %OpenApiSpex.MediaType{
                schema: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
              }
            }
          }
        }
      }
    })
    |> Map.put("/api/v1/docs", %OpenApiSpex.PathItem{
      get: %OpenApiSpex.Operation{
        operationId: "documentation.ui",
        summary: "Open the interactive API documentation",
        security: [],
        responses: %{
          "200" => %OpenApiSpex.Response{
            description: "Swagger UI",
            content: %{
              "text/html" => %OpenApiSpex.MediaType{schema: %OpenApiSpex.Schema{type: :string}}
            }
          }
        }
      }
    })
  end
end
