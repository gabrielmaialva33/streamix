defmodule StreamixWeb.Api.V1.FallbackControllerTest do
  use StreamixWeb.ConnCase, async: true

  alias StreamixWeb.Api.V1.FallbackController

  test "translates tagged errors without changing their public code or message", %{conn: conn} do
    assert conn
           |> FallbackController.call({:error, :invalid_id, "Invalid provider id"})
           |> json_response(400) == %{
             "error" => %{"code" => "invalid_id", "message" => "Invalid provider id"}
           }

    assert conn
           |> FallbackController.call(
             {:error, :not_found, "content_not_found", "Content not found"}
           )
           |> json_response(404) == %{
             "error" => %{"code" => "content_not_found", "message" => "Content not found"}
           }
  end

  test "changesets expose only interpolated validation messages", %{conn: conn} do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{}, [:name])
      |> Ecto.Changeset.validate_required([:name])

    assert conn
           |> FallbackController.call({:error, changeset})
           |> json_response(422) == %{
             "error" => %{"code" => "validation_failed", "message" => "name: can't be blank"}
           }
  end
end
