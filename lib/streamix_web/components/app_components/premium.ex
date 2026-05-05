defmodule StreamixWeb.AppComponents.Premium do
  @moduledoc """
  Premium and plan-access UI components.
  """

  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  attr :class, :string, default: nil
  attr :label, :string, default: "Premium"

  def premium_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full border border-brand/30 bg-brand/10 px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide text-brand",
      @class
    ]}>
      <.icon name="hero-sparkles" class="size-3.5" />
      {@label}
    </span>
    """
  end

  attr :class, :string, default: nil
  attr :grants_global_access, :boolean, default: false
  attr :id, :string, default: nil

  def plan_access_badge(assigns) do
    assigns =
      assign(assigns,
        label: if(assigns.grants_global_access, do: "Premium", else: "Disponível sob ativação"),
        icon: if(assigns.grants_global_access, do: "hero-sparkles", else: "hero-clock"),
        variant: if(assigns.grants_global_access, do: "premium", else: "neutral")
      )

    ~H"""
    <span
      id={@id}
      data-variant={@variant}
      class={[
        "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wide",
        @grants_global_access &&
          "border-brand/30 bg-brand/10 text-brand",
        !@grants_global_access &&
          "border-border bg-surface-hover text-text-secondary",
        @class
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      {@label}
    </span>
    """
  end

  attr :class, :string, default: nil
  attr :current_scope, :any, default: nil
  attr :description, :string, default: nil
  attr :id, :string, default: "premium-cta-banner"
  attr :navigate, :string, default: nil
  attr :title, :string, default: nil
  attr :cta_label, :string, default: nil

  def premium_cta_banner(assigns) do
    if assigns.current_scope &&
         Streamix.Access.can_play_global_content?(
           assigns.current_scope.user,
           Streamix.Iptv.get_global_provider()
         ) do
      ~H""
    else
      render_premium_cta_banner(assigns)
    end
  end

  defp render_premium_cta_banner(assigns) do
    assigns = assign(assigns, :navigate, assigns.navigate || ~p"/plans")

    defaults =
      if assigns.current_scope do
        %{
          title: "Liberte o acesso global ao catálogo",
          description:
            "Ative um plano premium para acessar o catálogo global sem bloqueios e acompanhar sua assinatura em um só lugar.",
          cta_label: "Ver planos"
        }
      else
        %{
          title: "Conheça os planos premium",
          description:
            "Acesse o catálogo global e confira o que cada plano oferece antes de entrar ou criar sua conta.",
          cta_label: "Explorar planos"
        }
      end

    assigns =
      assigns
      |> assign_new(:title, fn -> defaults.title end)
      |> assign_new(:description, fn -> defaults.description end)
      |> assign_new(:cta_label, fn -> defaults.cta_label end)

    ~H"""
    <section
      id={@id}
      class={[
        "rounded-lg border border-brand/20 bg-surface p-5 sm:p-6 shadow-card",
        @class
      ]}
    >
      <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div class="space-y-2">
          <.premium_badge />
          <h2 class="text-xl sm:text-2xl font-semibold text-text-primary">{@title}</h2>
          <p class="text-sm sm:text-base text-text-secondary max-w-2xl">{@description}</p>
        </div>

        <.link
          navigate={@navigate}
          class="inline-flex items-center justify-center gap-2 rounded-lg bg-brand px-4 py-2.5 font-semibold text-white transition-all hover:-translate-y-0.5 hover:bg-brand-hover focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2 focus:ring-offset-background"
        >
          <.icon name="hero-sparkles" class="size-5" />
          {@cta_label}
        </.link>
      </div>
    </section>
    """
  end
end
