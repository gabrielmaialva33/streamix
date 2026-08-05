defmodule Streamix.Iptv.Streaming.StreamMultiplexer.Upstream do
  @moduledoc false

  alias Streamix.Iptv.Streaming.UpstreamPolicy

  @forwardable_headers ~w(content-type accept-ranges etag last-modified)

  def connect(nil, _validator, _connect_timeout), do: {:error, :missing_upstream_url}

  def connect(url, validator, connect_timeout) do
    with :ok <- validator.(url),
         %URI{host: host} = uri when is_binary(host) <- URI.parse(url) do
      scheme = if uri.scheme == "https", do: :https, else: :http
      port = uri.port || default_port(scheme)

      transport_opts =
        if scheme == :https,
          do: [cacerts: :public_key.cacerts_get(), timeout: connect_timeout],
          else: [timeout: connect_timeout]

      headers = [
        {"host", host},
        {"user-agent", UpstreamPolicy.user_agent()},
        {"accept", "*/*"},
        {"connection", "keep-alive"}
      ]

      with {:ok, mint_conn} <-
             Mint.HTTP.connect(scheme, host, port, transport_opts: transport_opts),
           {:ok, mint_conn, request_ref} <-
             Mint.HTTP.request(mint_conn, "GET", request_path(uri), headers, nil) do
        {:ok, mint_conn, request_ref}
      else
        {:error, mint_conn, reason} ->
          close(mint_conn)
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      _invalid_url -> {:error, :invalid_upstream_url}
    end
  end

  def close(nil), do: :ok

  def close(mint_conn) do
    Mint.HTTP.close(mint_conn)
    :ok
  rescue
    _error -> :ok
  end

  def filter_response_headers(headers) do
    Enum.filter(headers, fn {name, _value} -> String.downcase(name) in @forwardable_headers end)
  end

  def header_value(headers, target) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == target, do: value
    end)
  end

  def resolve_url(base_url, location) do
    base_url |> URI.parse() |> URI.merge(location) |> URI.to_string()
  end

  def normalize_urls(""), do: []
  def normalize_urls(url) when is_binary(url), do: [url]

  def normalize_urls(urls) when is_list(urls) do
    urls
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  def normalize_urls(_urls), do: []

  def safe_reason({:unexpected_status, status}), do: {:unexpected_status, status}
  def safe_reason(reason) when is_atom(reason), do: reason
  def safe_reason(%{__struct__: module}), do: module
  def safe_reason(_reason), do: :upstream_error

  defp default_port(:https), do: 443
  defp default_port(:http), do: 80

  defp request_path(uri) do
    path = uri.path || "/"
    if uri.query, do: "#{path}?#{uri.query}", else: path
  end
end
