defmodule StreamixWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality.
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import Phoenix.Controller, only: [get_csrf_token: 0]
  import StreamixWeb.App.Navigation
  import StreamixWeb.CoreComponents

  embed_templates "layouts/*"

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
      Regex.match?(~r{^/watch/}, path)
  end
end
