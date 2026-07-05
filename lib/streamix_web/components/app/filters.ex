defmodule StreamixWeb.App.Filters do
  @moduledoc """
  Search and category filter controls.
  """

  use Phoenix.Component

  import StreamixWeb.CoreComponents

  alias Phoenix.LiveView.JS

  attr :providers, :list, required: true
  attr :selected, :string, default: "all"
  attr :on_change, :string, default: "filter_provider"
  attr :class, :any, default: nil

  def provider_dropdown(assigns) do
    selected_provider =
      Enum.find(assigns.providers, &provider_selected?(&1, assigns.selected))

    assigns = assign(assigns, :selected_provider, selected_provider)

    ~H"""
    <div :if={@providers != []} id="provider-dropdown" class={["relative flex-shrink-0", @class]}>
      <button
        type="button"
        phx-click={JS.toggle(to: "#provider-dropdown-menu")}
        class={[
          "category-chip gap-1.5",
          @selected_provider && "category-chip--active pr-8"
        ]}
        aria-haspopup="listbox"
        aria-label="Filtrar por provedor"
        title={(@selected_provider && @selected_provider.name) || "Filtrar por provedor"}
      >
        <.icon name="hero-server-stack" class="size-4 flex-shrink-0" />
        <span class="truncate max-w-36">
          {(@selected_provider && @selected_provider.name) || "Provedor"}
        </span>
        <.icon
          :if={!@selected_provider}
          name="hero-chevron-down"
          class="size-3.5 flex-shrink-0 opacity-70"
        />
      </button>
      <button
        :if={@selected_provider}
        type="button"
        phx-click={@on_change}
        phx-value-provider="all"
        class="absolute right-2 top-1/2 -translate-y-1/2 flex items-center justify-center rounded-full p-0.5 text-white/80 hover:text-white hover:bg-white/20 transition-colors"
        aria-label="Limpar filtro de provedor"
        title="Voltar ao catálogo completo"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
      <div
        id="provider-dropdown-menu"
        class="hidden absolute left-0 top-full mt-2 w-60 glass rounded-xl shadow-dropdown py-1.5 z-50"
        phx-click-away={JS.hide(to: "#provider-dropdown-menu")}
        role="listbox"
      >
        <p class="px-3.5 pb-1.5 pt-1 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
          Filtrar por provedor
        </p>
        <button
          :for={provider <- @providers}
          type="button"
          role="option"
          aria-selected={to_string(provider_selected?(provider, @selected))}
          phx-click={
            JS.hide(to: "#provider-dropdown-menu")
            |> JS.push(@on_change, value: %{provider: provider_toggle_value(provider, @selected)})
          }
          class="flex w-full items-center justify-between gap-2 px-3.5 py-2 text-sm text-text-secondary hover:text-text-primary hover:bg-white/5 transition-colors"
          title={provider.name}
        >
          <span class="truncate">{provider.name}</span>
          <.icon
            :if={provider_selected?(provider, @selected)}
            name="hero-check"
            class="size-4 flex-shrink-0 text-brand"
          />
        </button>
      </div>
    </div>
    """
  end

  defp provider_selected?(provider, selected),
    do: to_string(provider.id) == to_string(selected)

  # Clicking the already-selected provider clears the filter back to the
  # unified catalog; there is no dedicated "all" entry in the menu.
  defp provider_toggle_value(provider, selected) do
    if provider_selected?(provider, selected), do: "all", else: to_string(provider.id)
  end

  attr :categories, :list, required: true
  attr :selected, :any, default: nil
  attr :on_change, :string, default: "filter_category"
  attr :visible_count, :integer, default: 6
  attr :layout, :atom, values: [:horizontal, :sidebar], default: :horizontal

  def category_filter_v2(%{layout: :sidebar} = assigns) do
    ~H"""
    <aside class="hidden sm:block w-full sm:w-56 lg:w-64 sm:sticky sm:top-24 self-start flex-shrink-0">
      <ul class="category-sidebar space-y-0.5 max-h-[calc(100dvh-7rem)] overflow-y-auto pr-1">
        <li>
          <button
            type="button"
            phx-click={@on_change}
            phx-value-category=""
            class={["category-pill--sidebar", !@selected && "category-pill--sidebar-active"]}
          >
            Todos
          </button>
        </li>
        <li :for={category <- @categories}>
          <button
            type="button"
            phx-click={@on_change}
            phx-value-category={category.id}
            class={[
              "category-pill--sidebar",
              to_string(@selected) == to_string(category.id) && "category-pill--sidebar-active"
            ]}
          >
            {category.name}
          </button>
        </li>
      </ul>
    </aside>
    <div class="sm:hidden w-full">
      <.category_filter_v2
        categories={@categories}
        selected={@selected}
        on_change={@on_change}
        visible_count={@visible_count}
        layout={:horizontal}
      />
    </div>
    """
  end

  def category_filter_v2(assigns) do
    {visible, overflow} = Enum.split(assigns.categories, assigns.visible_count)
    selected_in_overflow = in_overflow?(overflow, assigns.selected)
    selected_name = find_category_name(assigns.categories, assigns.selected)

    assigns =
      assigns
      |> assign(:visible, visible)
      |> assign(:overflow, overflow)
      |> assign(:selected_in_overflow, selected_in_overflow)
      |> assign(:selected_name, selected_name)

    ~H"""
    <div class="flex items-center gap-1.5 min-w-0">
      <div class="flex items-center gap-1.5 overflow-x-auto scrollbar-hide min-w-0">
        <button
          type="button"
          phx-click={@on_change}
          phx-value-category=""
          class={["category-chip", !@selected && "category-chip--active"]}
        >
          Todos
        </button>
        <button
          :for={category <- @visible}
          type="button"
          phx-click={@on_change}
          phx-value-category={category.id}
          class={[
            "category-chip",
            to_string(@selected) == to_string(category.id) && "category-chip--active"
          ]}
        >
          {category.name}
        </button>
      </div>
      <div
        :if={@overflow != []}
        id="category-more-wrapper"
        phx-update="ignore"
        class="relative flex-shrink-0"
        x-data="{ open: false }"
        @click.outside="open = false"
      >
        <button
          type="button"
          class={[
            "category-chip inline-flex items-center gap-1",
            @selected_in_overflow && "category-chip--active"
          ]}
          @click="open = !open"
        >
          <span>{if @selected_in_overflow, do: @selected_name, else: "Mais"}</span>
          <.icon name="hero-chevron-down-mini" class="size-3" />
        </button>
        <div
          x-show="open"
          x-transition:enter="transition ease-out duration-100"
          x-transition:enter-start="opacity-0 scale-95"
          x-transition:enter-end="opacity-100 scale-100"
          x-transition:leave="transition ease-in duration-75"
          x-transition:leave-start="opacity-100 scale-100"
          x-transition:leave-end="opacity-0 scale-95"
          x-cloak
          class="absolute right-0 z-50 mt-2 w-52 max-h-72 overflow-y-auto glass rounded-xl shadow-dropdown"
        >
          <div class="py-1">
            <button
              :for={category <- @overflow}
              type="button"
              phx-click={@on_change}
              phx-value-category={category.id}
              class={[
                "w-full px-3 py-2 text-left text-xs hover:bg-white/5 transition-colors",
                to_string(@selected) == to_string(category.id) &&
                  "text-brand font-medium"
              ]}
              @click="open = false"
            >
              {category.name}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :value, :string, default: ""
  attr :placeholder, :string, default: "Buscar..."
  attr :on_change, :string, default: "search"
  attr :class, :string, default: ""

  def search_input(assigns) do
    ~H"""
    <form
      phx-change={@on_change}
      phx-submit={@on_change}
      class={["search-expand flex-1", @class == "" && "max-w-xs sm:max-w-sm", @class]}
    >
      <.icon
        name="hero-magnifying-glass"
        class="absolute left-2.5 top-1/2 -translate-y-1/2 size-4 text-text-muted pointer-events-none z-10"
      />
      <input
        type="search"
        name="search"
        value={@value}
        placeholder={@placeholder}
        phx-debounce="300"
        autocomplete="off"
        autocapitalize="off"
        autocorrect="off"
        spellcheck="false"
        enterkeyhint="search"
        class="search-expand__input"
      />
    </form>
    """
  end

  defp in_overflow?(overflow, nil) when is_list(overflow), do: false

  defp in_overflow?(overflow, selected) do
    selected_str = to_string(selected)
    Enum.any?(overflow, fn cat -> to_string(cat.id) == selected_str end)
  end

  defp find_category_name(_categories, nil), do: nil

  defp find_category_name(categories, selected) do
    selected_str = to_string(selected)

    Enum.find_value(categories, fn cat ->
      if to_string(cat.id) == selected_str, do: cat.name
    end)
  end
end
