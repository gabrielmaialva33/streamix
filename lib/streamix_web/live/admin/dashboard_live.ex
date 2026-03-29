defmodule StreamixWeb.Admin.DashboardLive do
  use StreamixWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Admin — Dashboard", current_path: "/admin")}
  end

  def render(assigns) do
    ~H"""
    <div id="admin-dashboard">
      <h1 class="text-2xl font-bold text-text-primary">Dashboard</h1>
    </div>
    """
  end
end
