defmodule Streamix.Iptv.TmdbClient.Transport do
  @moduledoc false

  alias Streamix.Gindex.Pacer
  alias Streamix.Iptv.TmdbClient.Config
  alias Streamix.Iptv.TmdbTokenPool

  @base_url "https://api.themoviedb.org/3"
  @timeout :timer.seconds(10)
  @max_retries 3
  @initial_backoff 1000

  def get_movie(tmdb_id, profile) do
    tmdb_id
    |> movie_url()
    |> request(profile)
  end

  def get_series(tmdb_id, profile) do
    tmdb_id
    |> series_url()
    |> request(profile)
  end

  def get_season(series_tmdb_id, season_number, profile) do
    series_tmdb_id
    |> season_url(season_number)
    |> request(profile)
  end

  def search(type, query, year, profile) do
    type
    |> search_url(query, year)
    |> request(profile)
  end

  def image_url(path, size \\ "w500")
  def image_url(nil, _size), do: nil
  def image_url("", _size), do: nil

  def image_url(path, size) do
    "#{image_base_url()}/#{size}#{path}"
  end

  defp movie_url(tmdb_id) do
    "#{@base_url}/movie/#{tmdb_id}?append_to_response=credits,videos,release_dates,images&language=pt-BR&include_image_language=null"
  end

  defp series_url(tmdb_id) do
    "#{@base_url}/tv/#{tmdb_id}?append_to_response=credits,videos,content_ratings,images&language=pt-BR&include_image_language=null"
  end

  defp season_url(series_tmdb_id, season_number) do
    "#{@base_url}/tv/#{series_tmdb_id}/season/#{season_number}?language=pt-BR"
  end

  defp search_url(type, query, year) do
    query_encoded = URI.encode_www_form(query)

    case {type, year} do
      {:movie, nil} ->
        "#{@base_url}/search/movie?query=#{query_encoded}&language=pt-BR"

      {:movie, year} ->
        "#{@base_url}/search/movie?query=#{query_encoded}&year=#{year}&language=pt-BR"

      {:series, nil} ->
        "#{@base_url}/search/tv?query=#{query_encoded}&language=pt-BR"

      {:series, year} ->
        "#{@base_url}/search/tv?query=#{query_encoded}&first_air_date_year=#{year}&language=pt-BR"
    end
  end

  defp request(url, profile, retries \\ 0, last_token \\ nil) do
    maybe_pace(profile)

    token = pick_token(profile, last_token)

    headers = [
      {"Authorization", "Bearer #{token || Config.config(profile)[:api_token]}"},
      {"Accept", "application/json"}
    ]

    url
    |> Req.get(headers: headers, receive_timeout: @timeout, finch: [name: Streamix.Finch])
    |> handle_response(url, profile, retries, token)
  end

  defp pick_token(profile, nil), do: TmdbTokenPool.next(profile)
  defp pick_token(profile, previous), do: TmdbTokenPool.next_after(profile, previous)

  defp maybe_pace(:gindex), do: Pacer.acquire(:tmdb_gindex)
  defp maybe_pace(_), do: :ok

  defp handle_response({:ok, %{status: 200, body: body}}, _url, _profile, _retries, _token)
       when is_map(body) do
    {:ok, body}
  end

  defp handle_response({:ok, %{status: 200, body: body}}, _url, _profile, _retries, _token)
       when is_binary(body) do
    Jason.decode(body)
  end

  defp handle_response({:ok, %{status: 429} = response}, url, profile, retries, token)
       when retries < @max_retries do
    retry_after = get_retry_after(response)
    Process.sleep(retry_after)
    request(url, profile, retries + 1, token)
  end

  defp handle_response({:ok, %{status: 429}}, _url, _profile, _retries, _token),
    do: {:error, :rate_limited}

  defp handle_response({:ok, %{status: 404}}, _url, _profile, _retries, _token),
    do: {:error, :not_found}

  defp handle_response({:ok, %{status: 401}}, _url, _profile, _retries, _token),
    do: {:error, :unauthorized}

  defp handle_response({:ok, %{status: status}}, _url, _profile, _retries, _token),
    do: {:error, {:http_error, status}}

  defp handle_response(
         {:error, %Req.TransportError{reason: reason}},
         _url,
         _profile,
         _retries,
         _token
       ),
       do: {:error, {:transport_error, reason}}

  defp handle_response({:error, reason}, _url, _profile, _retries, _token),
    do: {:error, reason}

  defp get_retry_after(%Req.Response{} = response),
    do: Req.Response.get_retry_after(response) || @initial_backoff

  defp image_base_url do
    "#{Application.get_env(:streamix, :tmdb_proxy_url, "https://tmdb.mahina.cloud")}/t/p"
  end
end
