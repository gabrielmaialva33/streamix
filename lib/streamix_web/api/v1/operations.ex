defmodule StreamixWeb.Api.V1.Operations do
  @moduledoc "Shared documentation defaults; these do not cast or change request parameters."

  alias StreamixWeb.Api.V1.Schemas

  def build(id, summary, response_schema, opts \\ []) do
    errors = [:bad_request, :unauthorized, :too_many_requests] ++ Keyword.get(opts, :errors, [])

    responses =
      Enum.map(Enum.uniq(errors), fn status ->
        {status,
         {Plug.Conn.Status.reason_phrase(Plug.Conn.Status.code(status)), "application/json",
          Schemas.ref("ApiErrorResponse")}}
      end)

    success =
      if response_schema do
        {summary, Keyword.get(opts, :content_type, "application/json"),
         Schemas.ref(response_schema)}
      else
        %OpenApiSpex.Response{description: summary}
      end

    spec = [
      operation_id: id,
      summary: summary,
      tags: [id |> String.split(".") |> hd() |> String.capitalize()],
      parameters: Keyword.get(opts, :parameters, []),
      security: Keyword.get(opts, :security, [%{"ApiKeyAuth" => []}]),
      responses:
        Keyword.merge(
          responses,
          [{Keyword.get(opts, :status, :ok), success}] ++ Keyword.get(opts, :responses, [])
        )
    ]

    case opts[:body] do
      nil ->
        spec

      schema ->
        Keyword.put(
          spec,
          :request_body,
          {summary, "application/json", Schemas.ref(schema), [required: true]}
        )
    end
  end

  def path(name, type \\ :string), do: {name, [in: :path, required: true, type: type]}
  def query(name, type \\ :string), do: {name, [in: :query, type: type]}
  def authenticated, do: [%{"ApiKeyAuth" => [], "BearerAuth" => []}]
  def bearer, do: [%{"BearerAuth" => []}]
end
