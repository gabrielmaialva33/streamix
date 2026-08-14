defmodule Streamix.ReleaseBuilder do
  @moduledoc false

  @color_app :color
  @unicode_delta "Δ"

  @spec prepare(Mix.Release.t()) :: Mix.Release.t()
  def prepare(%Mix.Release{} = release) do
    case Map.fetch(release.applications, @color_app) do
      {:ok, properties} ->
        properties
        |> Keyword.fetch!(:path)
        |> Path.join("ebin/color.app")
        |> normalize_color_description!()

      :error ->
        :ok
    end

    release
  end

  defp normalize_color_description!(path) do
    case :file.consult(path) do
      {:ok, [{:application, @color_app, properties}]} ->
        normalize_properties!(properties, path)

      {:ok, terms} ->
        Mix.raise("invalid color application spec at #{path}: #{inspect(terms)}")

      {:error, reason} ->
        Mix.raise(
          "could not read color application spec at #{path}: #{:file.format_error(reason)}"
        )
    end
  end

  defp normalize_properties!(properties, path) do
    case Keyword.fetch(properties, :description) do
      {:ok, description} when is_list(description) ->
        normalize_description!(properties, description, path)

      {:ok, _description} ->
        :ok

      :error ->
        :ok
    end
  end

  defp normalize_description!(properties, description, path) do
    if byte_charlist?(description) do
      :ok
    else
      # color 0.13.0 emits a Unicode charlist containing Δ. Mix.Release
      # passes application specs directly to File.write!/2, whose iodata
      # contract only accepts integer bytes. Keep the latest dependency and
      # normalize only its build metadata until upstream ships a byte-safe spec.
      properties
      |> Keyword.put(:description, ascii_description(description))
      |> then(&{:application, @color_app, &1})
      |> write_application_spec!(path)

      Mix.shell().info("* normalized color application metadata for release assembly")
    end
  end

  defp ascii_description(description) do
    normalized =
      description
      |> List.to_string()
      |> String.replace(@unicode_delta, "Delta")
      |> String.to_charlist()

    if byte_charlist?(normalized) do
      normalized
    else
      ~c"Color library for Elixir"
    end
  end

  defp byte_charlist?(value),
    do: Enum.all?(value, &(is_integer(&1) and &1 in 0..255))

  defp write_application_spec!(application, path) do
    temporary_path = path <> ".streamix-release"
    contents = :io_lib.format("~tp.~n", [application])

    File.write!(temporary_path, contents)
    File.rename!(temporary_path, path)
  end
end
