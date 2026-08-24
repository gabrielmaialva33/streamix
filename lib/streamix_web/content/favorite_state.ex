defmodule StreamixWeb.Content.FavoriteState do
  @moduledoc """
  Shared favorite toggling helpers for LiveView surfaces.
  """

  alias Streamix.Library

  @type status :: :added | :removed

  def toggle(user_id, content_type, content_id, attrs \\ %{})

  def toggle(nil, _content_type, _content_id, _attrs), do: {:error, :unauthorized}

  def toggle(user_id, content_type, content_id, attrs) do
    Library.toggle_favorite(user_id, content_type, content_id, attrs)
  end

  def apply_map(socket, assign_key, content_id, :added) do
    update_map(socket, assign_key, &MapSet.put(&1, content_id))
  end

  def apply_map(socket, assign_key, content_id, :removed) do
    update_map(socket, assign_key, &MapSet.delete(&1, content_id))
  end

  def boolean(:added), do: true
  def boolean(:removed), do: false

  def preserve_boolean(_current, {:ok, status}), do: boolean(status)
  def preserve_boolean(current, {:error, _reason}), do: current

  defp update_map(socket, assign_key, update_fun) do
    current = Map.get(socket.assigns, assign_key, MapSet.new())
    put_in(socket.assigns[assign_key], update_fun.(current))
  end
end
