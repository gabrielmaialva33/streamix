defmodule StreamixWeb.Api.V1.Schemas do
  @moduledoc """
  Named OpenAPI components for the external v1 contract.

  Controllers reference components through `ref/1`; the API spec owns the
  complete registry. Keeping the registry explicit makes duplicate titles and
  undocumented transport maps visible during review.
  """

  alias StreamixWeb.Api.V1.Schemas.{Catalog, Common}

  def schemas do
    Map.merge(Common.schemas(), Catalog.schemas(), fn title, _common, _catalog ->
      raise ArgumentError, "duplicate OpenAPI schema title: #{title}"
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
end
