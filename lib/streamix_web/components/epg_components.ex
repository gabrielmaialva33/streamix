defmodule StreamixWeb.EpgComponents do
  @moduledoc """
  UI components for EPG (Electronic Program Guide) display.
  """
  use Phoenix.Component

  alias Streamix.Iptv.EpgProgram

  @doc """
  Displays current program info with progress bar.
  Shows "Ao Vivo" badge, program title, and progress indicator.
  """
  attr :current_program, :any, default: nil
  attr :compact, :boolean, default: true

  def epg_now(assigns) do
    ~H"""
    <div :if={@current_program} class="mt-1.5 space-y-1">
      <div class="flex items-center gap-1.5">
        <span class="inline-flex items-center px-1 py-0.5 text-[9px] font-semibold rounded bg-red-500/90 text-white uppercase tracking-wide">
          Ao Vivo
        </span>
        <p class="text-[11px] text-text-secondary truncate flex-1" title={@current_program.title}>
          {@current_program.title}
        </p>
      </div>

      <.epg_progress_bar program={@current_program} />
    </div>

    <div :if={!@current_program} class="mt-1.5">
      <p class="text-[10px] text-text-muted italic">Sem programação</p>
    </div>
    """
  end

  @doc """
  Progress bar showing how much of the program has elapsed.
  """
  attr :program, :any, required: true

  def epg_progress_bar(assigns) do
    progress = if assigns.program, do: EpgProgram.progress(assigns.program), else: 0
    assigns = assign(assigns, :progress, progress)

    ~H"""
    <div class="h-0.5 bg-surface-hover rounded-full overflow-hidden">
      <div class="h-full bg-brand/80 transition-all duration-300" style={"width: #{@progress}%"} />
    </div>
    """
  end

  @doc """
  Displays current and next program info.
  Used when more space is available.
  """
  attr :current_program, :any, default: nil
  attr :next_program, :any, default: nil

  def epg_now_next(assigns) do
    ~H"""
    <div :if={@current_program} class="space-y-2">
      <div class="space-y-1">
        <div class="flex items-center gap-2">
          <span class="inline-flex items-center px-1.5 py-0.5 text-[10px] font-semibold rounded bg-red-500 text-white uppercase">
            Ao Vivo
          </span>
          <p class="text-sm text-text-primary truncate flex-1" title={@current_program.title}>
            {@current_program.title}
          </p>
        </div>

        <.epg_progress_bar program={@current_program} />

        <p :if={@current_program.description} class="text-xs text-text-secondary line-clamp-2">
          {@current_program.description}
        </p>
      </div>

      <div :if={@next_program} class="pt-1 border-t border-border/50">
        <div class="flex items-center gap-2 text-text-muted">
          <span class="text-[10px] uppercase font-medium">A seguir:</span>
          <p class="text-xs truncate flex-1">{@next_program.title}</p>
          <span class="text-[10px]">{format_time(@next_program.start_time)}</span>
        </div>
      </div>
    </div>

    <div :if={!@current_program} class="py-2">
      <p class="text-xs text-text-muted italic">Sem informação de programação</p>
    </div>
    """
  end

  defp format_time(nil), do: ""

  defp format_time(%DateTime{} = dt) do
    # Convert to local time (Brazil)
    dt
    |> DateTime.shift_zone!("America/Sao_Paulo")
    |> Calendar.strftime("%H:%M")
  rescue
    _ -> Calendar.strftime(dt, "%H:%M")
  end
end
