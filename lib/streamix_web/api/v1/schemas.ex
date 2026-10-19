defmodule StreamixWeb.Api.V1.Schemas do
  @moduledoc """
  Named OpenAPI components for the external v1 contract.

  Controllers reference components through `ref/1`; the API spec owns the
  complete registry. Keeping the registry explicit makes duplicate titles and
  undocumented transport maps visible during review.
  """

  alias StreamixWeb.Api.V1.Schemas.{Catalog, Common, Reels}

  def schemas do
    [Common.schemas(), Catalog.schemas(), Reels.schemas()]
    |> Enum.reduce(fn schemas, registry ->
      Map.merge(registry, schemas, fn title, _registered, _duplicate ->
        raise ArgumentError, "duplicate OpenAPI schema title: #{title}"
      end)
    end)
  end

  defdelegate ref(name), to: Common
  defdelegate movies_parameters(), to: Catalog
  defdelegate featured_parameters(), to: Catalog
  defdelegate series_parameters(), to: Catalog
  defdelegate channels_parameters(), to: Catalog
  defdelegate categories_parameters(), to: Catalog
  defdelegate search_parameters(), to: Catalog
  defdelegate suggest_parameters(), to: Catalog
  defdelegate home_parameters(), to: Catalog
  defdelegate shelf_parameters(), to: Catalog
  defdelegate id_parameter(resource), to: Catalog
  defdelegate reels_parameters(), to: Reels, as: :list_parameters
end
