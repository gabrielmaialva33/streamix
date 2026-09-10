defmodule Streamix.Embedplay.CatalogClient do
  @moduledoc false

  @catalog_url "https://embedplayapi.top/api/all-ids"
  @max_movies 100_000

  def movies do
    options = Application.get_env(:streamix, :embedplay_catalog_request_options, [])

    case Req.get(
           Keyword.merge(options,
             url: @catalog_url,
             params: [type: "movie"],
             redirect: false,
             retry: false,
             receive_timeout: 20_000,
             decode_body: false
           )
         ) do
      {:ok, %{status: 200, body: body}} -> parse(body)
      {:ok, _response} -> {:error, :catalog_unavailable}
      {:error, _reason} -> {:error, :catalog_unavailable}
    end
  end

  defp parse(body) when is_binary(body) and byte_size(body) <= 10_000_000 do
    case Jason.decode(body) do
      {:ok, decoded} -> parse(decoded)
      {:error, _reason} -> {:error, :invalid_catalog}
    end
  end

  defp parse(%{"status" => "success", "results" => %{"movies" => movies}})
       when is_list(movies) and length(movies) <= @max_movies do
    if movies == [], do: {:error, :empty_catalog}, else: {:ok, movies}
  end

  defp parse(_body), do: {:error, :invalid_catalog}
end
