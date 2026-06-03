defmodule Streamix.Gindex.Response do
  @moduledoc """
  Parses GIndex worker responses into Streamix data maps.
  """

  alias Streamix.Gindex.Url

  def parse_folder(body, base_url, current_path) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> parse_folder_data(data, base_url, current_path)
      {:error, _} -> {:error, :invalid_json_response}
    end
  end

  def parse_folder(body, base_url, current_path) when is_map(body) do
    parse_folder_data(body, base_url, current_path)
  end

  def parse_folder_with_token(body, base_url, current_path) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> parse_folder_data_with_token(data, base_url, current_path)
      {:error, _} -> {:error, :invalid_json_response}
    end
  end

  def parse_folder_with_token(body, base_url, current_path) when is_map(body) do
    parse_folder_data_with_token(body, base_url, current_path)
  end

  def extract_download_link(body, base_url) when is_map(body) do
    case body do
      %{"link" => link} when is_binary(link) and link != "" ->
        {:ok, base_url |> Url.join(link) |> ensure_inline_download()}

      _ ->
        {:error, :download_url_not_found}
    end
  end

  def extract_download_link(body, base_url) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> extract_download_link(data, base_url)
      {:error, _} -> {:error, :invalid_json_response}
    end
  end

  def file_info(headers) do
    %{
      size: get_header(headers, "content-length") |> parse_int(),
      content_type: get_header(headers, "content-type"),
      modified: get_header(headers, "last-modified")
    }
  end

  defp parse_folder_data(%{"data" => %{"files" => files}}, base_url, current_path)
       when is_list(files) do
    {:ok, Enum.map(files, &parse_file_item(&1, base_url, current_path))}
  end

  defp parse_folder_data(%{"files" => files}, base_url, current_path) when is_list(files) do
    {:ok, Enum.map(files, &parse_file_item(&1, base_url, current_path))}
  end

  defp parse_folder_data(data, base_url, current_path) do
    items =
      data
      |> extract_files_from_response()
      |> Enum.map(&parse_file_item(&1, base_url, current_path))

    {:ok, items}
  end

  defp parse_folder_data_with_token(%{"data" => data}, base_url, current_path)
       when is_map(data) do
    files = Map.get(data, "files", [])
    next_token = Map.get(data, "nextPageToken")
    items = Enum.map(files, &parse_file_item(&1, base_url, current_path))
    {:ok, items, next_token}
  end

  defp parse_folder_data_with_token(%{"files" => files} = data, base_url, current_path)
       when is_list(files) do
    next_token = Map.get(data, "nextPageToken")
    items = Enum.map(files, &parse_file_item(&1, base_url, current_path))
    {:ok, items, next_token}
  end

  defp parse_folder_data_with_token(data, base_url, current_path) do
    files = extract_files_from_response(data)
    next_token = extract_next_page_token(data)
    items = Enum.map(files, &parse_file_item(&1, base_url, current_path))
    {:ok, items, next_token}
  end

  defp extract_files_from_response(%{"data" => data}) when is_map(data) do
    Map.get(data, "files", [])
  end

  defp extract_files_from_response(%{"files" => files}) when is_list(files), do: files
  defp extract_files_from_response(_), do: []

  defp extract_next_page_token(%{"data" => data}) when is_map(data) do
    Map.get(data, "nextPageToken")
  end

  defp extract_next_page_token(%{"nextPageToken" => token}), do: token
  defp extract_next_page_token(_), do: nil

  defp parse_file_item(item, _base_url, current_path) do
    name = item["name"] || item["title"] || ""
    mime_type = item["mimeType"] || item["mime_type"] || ""
    size = item["size"] || 0

    type = determine_file_type(mime_type, name)
    path = build_file_path(current_path, name, type)

    %{
      name: String.trim_trailing(name, "/"),
      type: type,
      path: path,
      size: parse_size(size),
      mime_type: mime_type,
      modified: item["modifiedTime"] || item["modified_time"]
    }
  end

  defp determine_file_type(mime_type, name) do
    if mime_type == "application/vnd.google-apps.folder" or String.ends_with?(name, "/") do
      :folder
    else
      :file
    end
  end

  defp build_file_path(current_path, name, :folder) do
    Path.join(current_path, name) <> "/"
  end

  defp build_file_path(current_path, name, :file) do
    Path.join(current_path, name)
  end

  defp parse_size(size) when is_integer(size), do: size
  defp parse_size(size) when is_binary(size), do: parse_int(size)
  defp parse_size(_), do: 0

  defp parse_int(nil), do: nil
  defp parse_int(str) when is_binary(str), do: String.to_integer(str)
  defp parse_int(num) when is_integer(num), do: num

  defp ensure_inline_download(url) do
    uri = URI.parse(url)

    if uri.path == "/download.aspx" do
      query =
        uri.query
        |> URI.decode_query()
        |> Map.put("inline", "true")

      %{uri | query: URI.encode_query(query)}
      |> URI.to_string()
    else
      url
    end
  end

  defp get_header(headers, name) do
    name_lower = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name_lower, do: value
    end)
  end
end
