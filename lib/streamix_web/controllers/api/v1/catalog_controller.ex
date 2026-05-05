defmodule StreamixWeb.Api.V1.CatalogController do
  @moduledoc """
  Public catalog API for TV app and other clients.

  This controller is intentionally thin: it owns HTTP status/JSON wiring
  while `StreamixWeb.Catalog.Api` composes catalog payloads.
  """

  use StreamixWeb, :controller

  alias StreamixWeb.Catalog.Api

  def options(conn, _params) do
    conn
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
    |> send_resp(204, "")
  end

  def featured(conn, _params), do: json(conn, Api.featured())
  def movies(conn, params), do: json(conn, Api.movies(params))
  def series(conn, params), do: json(conn, Api.series(params))
  def channels(conn, params), do: json(conn, Api.channels(params))
  def categories(conn, params), do: json(conn, Api.categories(params))
  def search(conn, params), do: json(conn, Api.search(params))
  def suggest(conn, params), do: json(conn, Api.suggest(params))
  def home(conn, params), do: json(conn, Api.home(params))
  def trending(conn, params), do: json(conn, Api.trending(params))
  def recent(conn, params), do: json(conn, Api.recent(params))
  def top_rated(conn, params), do: json(conn, Api.top_rated(params))

  def show_movie(conn, %{"id" => id}) do
    render_result(conn, Api.movie_detail(id), "Movie not found")
  end

  def show_series(conn, %{"id" => id}) do
    render_result(conn, Api.series_detail(id), "Series not found")
  end

  def show_episode(conn, %{"id" => id}) do
    render_result(conn, Api.episode_detail(id), "Episode not found")
  end

  def show_channel(conn, %{"id" => id}) do
    render_result(conn, Api.channel_detail(id), "Channel not found")
  end

  def movie_stream(conn, %{"id" => id}) do
    render_result(conn, Api.movie_stream(id), "Movie not found")
  end

  def episode_stream(conn, %{"id" => id}) do
    render_result(conn, Api.episode_stream(id), "Episode not found")
  end

  def channel_stream(conn, %{"id" => id}) do
    render_result(conn, Api.channel_stream(id), "Channel not found")
  end

  defp render_result(conn, {:ok, payload}, _not_found_message), do: json(conn, payload)

  defp render_result(conn, {:error, :not_found}, not_found_message) do
    conn
    |> put_status(:not_found)
    |> json(%{error: not_found_message})
  end
end
