defmodule Streamix.Iptv.Streaming.UpstreamPolicy do
  @moduledoc """
  Shared outbound identity for Xtream control-plane and media requests.

  Providers commonly include the User-Agent in WAF and account policies. Keeping
  it behind one function prevents catalog sync, health probes, redirect walking,
  direct proxying, and the live multiplexer from presenting different clients.
  """

  @default_user_agent "IPTVSmartersPlayer"

  @doc "Returns the User-Agent sent to Xtream providers and their media edges."
  @spec user_agent() :: String.t()
  def user_agent do
    case Application.get_env(:streamix, :iptv_upstream_user_agent, @default_user_agent) do
      value when is_binary(value) and value != "" -> value
      _ -> @default_user_agent
    end
  end
end
