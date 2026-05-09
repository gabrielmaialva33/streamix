defmodule StreamixWeb.Admin.PwaDebugLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AdminComponents

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Admin - Debug PWA",
       current_path: "/debug/pwa",
       server_debug: server_debug()
     )}
  end

  def render(assigns) do
    ~H"""
    <div id="admin-pwa-debug" class="space-y-6">
      <.admin_tabs current_path={@current_path} />

      <section class="rounded-lg border border-border bg-surface p-5 shadow-card">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <p class="text-sm font-medium uppercase tracking-wide text-brand">Debug</p>
            <h1 class="mt-1 text-2xl font-semibold text-text-primary">PWA / iOS Safari</h1>
            <p class="mt-2 max-w-2xl text-sm text-text-secondary">
              Abra esta página no aparelho que você quer diagnosticar. No iPhone ela captura modo PWA,
              Safari, service worker, cache, storage e estado local do player.
            </p>
          </div>

          <div class="flex flex-wrap gap-2">
            <button
              id="pwa-debug-refresh"
              type="button"
              class="inline-flex items-center gap-2 rounded-md border border-border px-3 py-2 text-sm font-medium text-text-primary transition-colors hover:bg-surface-hover"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Atualizar
            </button>
            <button
              id="pwa-debug-download"
              type="button"
              class="inline-flex items-center gap-2 rounded-md bg-brand px-3 py-2 text-sm font-medium text-white transition-colors hover:bg-brand/90"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Baixar TXT
            </button>
          </div>
        </div>
      </section>

      <section
        id="pwa-debug"
        phx-hook="PwaDebug"
        data-server-debug={Jason.encode!(@server_debug)}
        class="rounded-lg border border-border bg-surface p-5 shadow-card"
      >
        <div class="mb-4 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <h2 class="text-lg font-semibold text-text-primary">Snapshot do ambiente</h2>
          <p id="pwa-debug-status" class="text-sm text-text-secondary">Coletando...</p>
        </div>

        <pre
          id="pwa-debug-output"
          class="max-h-[70vh] overflow-auto rounded-md border border-border bg-background p-4 text-xs leading-relaxed text-text-primary whitespace-pre-wrap"
        >Coletando informações...</pre>
      </section>
    </div>
    """
  end

  defp server_debug do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      app_version: Application.spec(:streamix, :vsn) |> to_string(),
      endpoint_url: StreamixWeb.Endpoint.url(),
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> List.to_string(),
      static_paths: StreamixWeb.static_paths()
    }
  end
end
