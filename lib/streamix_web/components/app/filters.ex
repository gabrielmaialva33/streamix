defmodule StreamixWeb.App.Filters do
  @moduledoc """
  Search and category filter controls.
  """

  use Phoenix.Component

  import StreamixWeb.CoreComponents

  attr :providers, :list, required: true
  attr :selected, :string, default: "all"
  attr :on_change, :string, default: "filter_provider"

  def provider_filter(assigns) do
    ~H"""
    <div :if={@providers != []} class="flex items-center gap-1.5 min-w-0">
      <span class="hidden lg:inline text-xs font-medium text-text-muted">Provider</span>
      <div class="flex min-w-0 items-center gap-1.5 overflow-x-auto scrollbar-hide">
        <button
          type="button"
          phx-click={@on_change}
          phx-value-provider="all"
          class={[
            "category-chip whitespace-nowrap",
            @selected in [nil, "all"] && "category-chip--active"
          ]}
        >
          Todos
        </button>
        <button
          :for={provider <- @providers}
          type="button"
          phx-click={@on_change}
          phx-value-provider={provider.id}
          class={[
            "category-chip max-w-44 whitespace-nowrap",
            to_string(@selected) == to_string(provider.id) && "category-chip--active"
          ]}
          title={provider.name}
        >
          <span class="truncate">{provider.name}</span>
        </button>
      </div>
    </div>
    """
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
