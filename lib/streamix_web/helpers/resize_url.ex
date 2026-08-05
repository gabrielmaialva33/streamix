defmodule StreamixWeb.Helpers.ResizeUrl do
  @moduledoc """
  Builds absolute URLs pointing at
  `Streamix.V1.Api.ImageResizeController.resize/2` so that serializers can
  hand clients a set of pre-sized variants (`poster_w480`, `poster_w720`,
  `backdrop_w1280`, …) instead of forcing them to pick a resize on the
  device.

  The `"raw"` key preserves the original CDN URL so older clients that
  don't understand the variants keep working unchanged.
  """

  alias StreamixWeb.Endpoint

  @resize_path "/api/v1/catalog/images/resize"

  @type width :: pos_integer()

  @doc """
  Returns a flat map suitable for merging into a JSON response.

  The `prefix` becomes the leading segment of each key: with `"poster"`
  and widths `[480, 720]` you get `%{"poster_w480" => ..., "poster_w720" => ...}`.
  `nil`/empty input returns `%{}` so callers can `Map.merge/2` it
  unconditionally.
  """
  @spec flatten(String.t(), String.t() | nil, [width()]) :: %{String.t() => String.t()}
  def flatten(_prefix, nil, _widths), do: %{}
  def flatten(_prefix, "", _widths), do: %{}

  def flatten(prefix, url, widths)
      when is_binary(prefix) and is_binary(url) and is_list(widths) do
    Enum.reduce(widths, %{}, fn w, acc ->
      Map.put(acc, "#{prefix}_w#{w}", variant_url(url, w))
    end)
  end

  @doc """
  Same as `flatten/3` but returns `%{"raw" => url, "w480" => ..., "w720" => ...}`
  without a prefix — useful when the caller already nests the key
  (`%{poster: variants(...)}`).
  """
  @spec variants(String.t() | nil, [width()]) :: %{String.t() => String.t()}
  def variants(nil, _widths), do: %{}
  def variants("", _widths), do: %{}

  def variants(url, widths) when is_binary(url) and is_list(widths) do
    widths
    |> Enum.reduce(%{"raw" => url}, fn w, acc ->
      Map.put(acc, "w#{w}", variant_url(url, w))
    end)
  end

  defp variant_url(url, w) do
    "#{endpoint_url()}#{@resize_path}?url=#{URI.encode_www_form(url)}&w=#{w}"
  end

  # `Endpoint.url/0` respects the deployment scheme/host from
  # config/runtime.exs, so these are always canonical absolute URLs.
  defp endpoint_url, do: Endpoint.url()
end
