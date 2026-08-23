defmodule StreamixWeb.WatchPartyLive.Status do
  @moduledoc """
  Presentation policy for Watch Party synchronization state.

  Keeping status visibility, copy and color outside the LiveView prevents
  transport events from accumulating UI conditionals and makes the stable
  state intentionally silent for both host and viewers.
  """

  use Gettext, backend: StreamixWeb.Gettext

  @base_class "inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-medium shadow-card backdrop-blur-sm"

  def show?(false, :offline, _sync_status), do: true
  def show?(_is_host, _host_status, sync_status), do: sync_status != "synced"

  def text(false, :offline, _sync_status, _drift_ms),
    do: gettext("Anfitrião desconectado — aguardando retorno")

  def text(_is_host, _host_status, "disconnected", _drift_ms),
    do: gettext("Sincronização desconectada")

  def text(_is_host, _host_status, "buffering", _drift_ms),
    do: gettext("Aguardando o buffer")

  def text(_is_host, _host_status, "connecting", _drift_ms),
    do: gettext("Conectando à sincronização")

  def text(_is_host, _host_status, "correcting", drift_ms)
      when is_integer(drift_ms) and drift_ms > 0,
      do: gettext("Ajustando sincronização (%{drift} ms)", drift: drift_ms)

  def text(_is_host, _host_status, "correcting", _drift_ms),
    do: gettext("Ajustando sincronização")

  def text(true, _host_status, _sync_status, _drift_ms),
    do: gettext("Você controla a reprodução")

  def text(false, _host_status, _sync_status, drift_ms)
      when is_integer(drift_ms) and drift_ms >= 100,
      do: gettext("Sincronizado com o anfitrião (%{drift} ms)", drift: drift_ms)

  def text(false, _host_status, _sync_status, _drift_ms),
    do: gettext("Sincronizado com o anfitrião")

  def class(is_host, host_status, sync_status) do
    modifier =
      cond do
        host_status == :offline ->
          " bg-warning/90 text-black"

        sync_status == "disconnected" ->
          " bg-error/90 text-white"

        sync_status in ["connecting", "correcting", "buffering"] ->
          " bg-warning/90 text-black"

        is_host ->
          " bg-brand/90 text-white"

        true ->
          " bg-success/90 text-black"
      end

    @base_class <> modifier
  end
end
