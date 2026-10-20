defmodule StreamixWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality.
  """
  use Phoenix.Component
  use Gettext, backend: StreamixWeb.Gettext
  use StreamixWeb, :verified_routes

  import Phoenix.Controller, only: [get_csrf_token: 0]
  import StreamixWeb.App.Navigation
  import StreamixWeb.CoreComponents

  embed_templates "layouts/*"

  @doc """
  The page's title for the root layout. Error pages have no `page_title`
  assign, only the `status` Phoenix renders them with.
  """
  def page_title(%{page_title: title}) when is_binary(title) and title != "", do: title
  def page_title(%{status: 404}), do: "Página não encontrada"

  def page_title(%{status: status}) when is_integer(status) and status >= 500,
    do: "Algo deu errado"

  def page_title(_assigns), do: nil

  def hero_path?(path) when is_binary(path) do
    path = path |> String.split("?", parts: 2) |> List.first()

    path in ["/", "/home"] or
      Regex.match?(~r{^/(browse|providers/\d+)/(movies|series)/\d+}, path)
  end

  def hero_path?(_), do: false

  def detail_path?(path) when is_binary(path) do
    path
    |> String.split("?", parts: 2)
    |> List.first()
    |> do_detail_path?()
  end

  def detail_path?(_), do: false

  defp do_detail_path?(path) do
    Regex.match?(~r{^/browse/(movies|series)/\d+}, path) or
      Regex.match?(~r{^/providers/\d+/(movies|series)/\d+}, path) or
      Regex.match?(~r{^/gindex/(movies|series|animes)/\d+}, path) or
      Regex.match?(~r{^/watch/}, path)
  end
end
