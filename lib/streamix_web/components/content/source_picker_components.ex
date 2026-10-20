defmodule StreamixWeb.SourcePickerComponents do
  @moduledoc "Shared source selection for series and episode detail pages."
  use Phoenix.Component

  import StreamixWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :options, :list, required: true
  attr :selected, :integer, required: true
  attr :event, :string, required: true

  def source_picker(assigns) do
    ~H"""
    <div
      :if={length(@options) > 1}
      id={@id}
      phx-hook=".SourcePicker"
      role="radiogroup"
      aria-label="Fonte"
      class="flex flex-wrap gap-2"
    >
      <button
        :for={option <- @options}
        id={"source-option-#{option.id}"}
        type="button"
        role="radio"
        aria-checked={to_string(option.id == @selected)}
        tabindex={if option.id == @selected, do: "0", else: "-1"}
        phx-click={@event}
        phx-value-id={option.id}
        class={[
          "min-h-11 rounded-lg border px-3 py-2 text-left text-sm focus-visible:outline-2 focus-visible:outline-brand",
          option.id == @selected && "border-brand bg-brand/10",
          option.id != @selected && "border-border bg-surface"
        ]}
      >
        <span class="font-semibold">{option.label}</span>
        <span :if={option.recommended} class="text-xs text-brand"> · Recomendada</span>
        <span :if={option.unstable} class="text-xs"> · Instável</span>
        <span :if={option.locked} class="text-xs">
          · <.icon name="hero-lock-closed" class="size-3" /> Premium
        </span>
        <span :for={badge <- option.badges} data-source-badge class="ml-1 text-xs">{badge}</span>
        <span :if={option.note} class="block text-xs text-text-secondary">{option.note}</span>
      </button>
    </div>
    <p :if={length(@options) == 1} id={@id <> "-info"} class="text-sm text-text-secondary">
      Fonte: {hd(@options).label}
      <span :if={hd(@options).unstable}> · Instável</span>
      <span :if={hd(@options).locked}>
        · <.icon name="hero-lock-closed" class="size-3" /> Premium
      </span>
      <span :for={badge <- hd(@options).badges} data-source-badge class="ml-1">{badge}</span>
      <span :if={hd(@options).note}> · {hd(@options).note}</span>
    </p>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SourcePicker">
      export default {
        mounted() {
          this.onKeyDown = (event) => {
            const offsets = {ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1}
            if (!(event.key in offsets)) return
            const options = Array.from(this.el.querySelectorAll('[role="radio"]'))
            const index = options.indexOf(event.target.closest('[role="radio"]'))
            if (index < 0) return
            event.preventDefault()
            const next = options[(index + offsets[event.key] + options.length) % options.length]
            next.focus()
            next.click()
          }
          this.el.addEventListener('keydown', this.onKeyDown)
        },
        destroyed() {
          this.el.removeEventListener('keydown', this.onKeyDown)
        }
      }
    </script>
    """
  end
end
