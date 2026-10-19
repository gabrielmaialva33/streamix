defmodule Streamix.Iptv.Streaming.UpstreamPolicy do
  @moduledoc """
  Shared outbound identity for Xtream control-plane and media requests.

  Providers commonly include the User-Agent in WAF and account policies. Keeping
  it behind one function prevents catalog sync, health probes, redirect walking,
  direct proxying, and the live multiplexer from presenting different clients.
  """

  alias Streamix.Iptv.Provider

  @default_user_agent "IPTVSmartersPlayer"

  @doc "Returns the User-Agent sent to Xtream providers and their media edges."
  @spec user_agent() :: String.t()
  def user_agent do
    case Application.get_env(:streamix, :iptv_upstream_user_agent, @default_user_agent) do
      value when is_binary(value) and value != "" -> value
      _ -> @default_user_agent
    end
  end

  @doc "Builds a credential-free identity scoped to the provider's registered panel hosts."
  def domain_policy(%Provider{send_x_domain: true} = provider) do
    %{
      hosts:
        provider
        |> Provider.url_chain()
        |> Enum.map(&host/1)
        |> Enum.reject(&is_nil/1),
      domain: public_domain()
    }
  end

  def domain_policy(_provider), do: nil

  @doc "Loads provider identity once at the playback boundary, before spawning fetch tasks."
  def with_domain_policy(opts) do
    Keyword.put_new_lazy(opts, :domain_policy, fn ->
      provider = Keyword.get(opts, :provider) || provider_by_id(Keyword.get(opts, :provider_id))
      domain_policy(provider)
    end)
  end

  defp provider_by_id(id) when is_integer(id), do: Streamix.Providers.get_provider(id)
  defp provider_by_id(_id), do: nil

  @doc "Recomputes X-Domain for this hop, removing any stale copy on non-panel hosts."
  def headers(url, headers, policy) do
    headers =
      Enum.reject(headers, fn {name, _} -> String.downcase(to_string(name)) == "x-domain" end)

    case policy do
      %{hosts: hosts, domain: domain} when is_binary(domain) ->
        if host(url) in hosts, do: [{"x-domain", domain} | headers], else: headers

      _ ->
        headers
    end
  end

  @doc "Applies a domain policy after all request options have been merged."
  def request_options(url, request_opts, opts) do
    Keyword.update(request_opts, :headers, headers(url, [], opts[:domain_policy]), fn headers ->
      headers(url, headers, opts[:domain_policy])
    end)
  end

  defp public_domain do
    value =
      Application.get_env(:streamix, :iptv_x_domain) ||
        Application.get_env(:streamix, :iptv_public_host)

    # A domain, never a URL, port, path or injected HTTP header.
    if is_binary(value) and Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\z/, value),
      do: String.downcase(value),
      else: nil
  end

  defp host(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) ->
        String.downcase(host)

      _ ->
        nil
    end
  end

  defp host(_url), do: nil
end
