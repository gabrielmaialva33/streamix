defmodule Streamix.Gindex.Parser.Files do
  @moduledoc """
  File-level helpers for GIndex parser modules.
  """

  # `ts` / `m2ts` show up on fansub drops of Blu-ray rips; `mpg`/`mpeg`
  # on older archival uploads. They all transcode fine.
  @video_extensions ~w(mkv mp4 avi mov wmv flv webm m4v ts m2ts mpg mpeg ogv 3gp)

  @doc """
  Determines if a filename is a supported video file.
  """
  def video_file?(nil), do: false

  def video_file?(filename) when is_binary(filename) do
    {_, ext} = split_extension(filename)
    String.downcase(ext || "") in @video_extensions
  end

  @doc """
  Extracts the file extension.
  """
  def split_extension(nil), do: {nil, nil}

  def split_extension(filename) when is_binary(filename) do
    case Path.extname(filename) do
      "" -> {filename, nil}
      ext -> {String.trim_trailing(filename, ext), String.trim_leading(ext, ".")}
    end
  end

  @doc """
  Generates a stable integer stream id from a GIndex path.
  """
  def path_to_stream_id(path) do
    :erlang.phash2(path)
  end

  @doc """
  Parses a human-readable file size to bytes.
  """
  def parse_file_size(size_str) when is_binary(size_str) do
    size_str = String.trim(size_str)

    case Regex.run(~r/^([\d.]+)\s*(GB|MB|KB|B)?$/i, size_str) do
      [_, num, unit] ->
        num = parse_float(num)
        multiplier = unit |> normalize_size_unit() |> size_multiplier()
        round(num * multiplier)

      nil ->
        0
    end
  end

  def parse_file_size(_), do: 0

  defp normalize_size_unit(""), do: "B"
  defp normalize_size_unit(unit), do: String.upcase(unit)

  defp parse_float(str) do
    case Float.parse(str) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp size_multiplier("GB"), do: 1024 * 1024 * 1024
  defp size_multiplier("MB"), do: 1024 * 1024
  defp size_multiplier("KB"), do: 1024
  defp size_multiplier(_), do: 1
end
