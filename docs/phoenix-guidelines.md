# Phoenix / LiveView / Ecto Guidelines

Detailed reference for Phoenix 1.8 patterns used in Streamix. Imported by CLAUDE.md.

## Elixir

- Lists don't support index access (`mylist[i]`) — use `Enum.at/2` or pattern matching.
- Variables are immutable but rebindable. Block expressions (`if`, `case`, `cond`) must bind their result:

```elixir
# VALID
socket =
  if connected?(socket) do
    assign(socket, :val, val)
  end

# INVALID — rebinding inside `if` has no effect outside
if connected?(socket) do
  socket = assign(socket, :val, val)
end
```

- Never nest multiple modules in the same file (causes cyclic deps).
- Never use map access syntax (`changeset[:field]`) on structs — use `my_struct.field` or `Ecto.Changeset.get_field/2`.
- Use `Task.async_stream/3` for concurrent work with back-pressure (usually `timeout: :infinity`).
- Predicate functions: end with `?`, never start with `is_` (reserve `is_` for guards).
- `DynamicSupervisor`, `Registry` need names in child spec: `{DynamicSupervisor, name: MyApp.MySup}`.
- Don't use `String.to_atom/1` on user input (memory leak risk).

## Phoenix Router

- `scope` blocks include an optional alias prefixed for all routes. Don't create redundant aliases:

```elixir
scope "/admin", StreamixWeb.Admin do
  pipe_through :browser
  live "/users", UserLive, :index  # → StreamixWeb.Admin.UserLive
end
```

- `Phoenix.View` is gone. Don't use it.

## Ecto

- Always preload associations in queries when accessed in templates.
- `Ecto.Schema` uses `:string` type for both `varchar` and `text` columns.
- `validate_number/2` does NOT support `:allow_nil` (validations skip nil by default).
- Use `Ecto.Changeset.get_field/2` to read changeset fields.
- Fields set programmatically (`user_id`) must NOT be in `cast/3` — set them explicitly.
- Always use `mix ecto.gen.migration name_in_snake_case`.
- `import Ecto.Query` in `seeds.exs`.

## HEEx Templates

- Always use `~H` or `.html.heex` files. Never `~E`.
- Use `Phoenix.Component.form/1` and `inputs_for/1`. Never `Phoenix.HTML.form_for`.
- Use `to_form/2` → `@form`. Access fields as `@form[:field]`. Never pass changesets to templates.
- Add unique DOM IDs to forms, buttons, key elements.
- Interpolation in attributes: `{@value}`. In tag bodies: `{@value}` or `<%= ... %>` for blocks.
- Never use `<%= @value %>` inside tag attributes.
- Class lists must use `[...]` syntax:

```heex
<a class={[
  "px-2 text-white",
  @active && "bg-brand",
  if(@condition, do: "border-red-500", else: "border-blue-100")
]}>Text</a>
```

- Comments: `<%!-- comment --%>` (HEEx syntax).
- Never use `<% Enum.each %>` — use `<%= for item <- @collection do %>`.
- Literal braces in `<pre>`/`<code>`: add `phx-no-curly-interpolation` to parent tag.
- Elixir has no `else if` / `elsif` in templates — use `cond` or `case`.

## LiveView

- Never use `live_redirect` / `live_patch` — use `<.link navigate={}>` / `<.link patch={}>`.
- Avoid LiveComponents unless there's a strong reason.
- LiveView names: `StreamixWeb.WeatherLive` (with `Live` suffix).

### Streams

Always use streams for collections (never assign raw lists):

```elixir
# Append
stream(socket, :messages, [new_msg])

# Reset (e.g., filtering)
stream(socket, :messages, filtered_msgs, reset: true)

# Prepend
stream(socket, :messages, [new_msg], at: -1)

# Delete
stream_delete(socket, :messages, msg)
```

Template:

```heex
<div id="messages" phx-update="stream">
  <div :for={{id, msg} <- @streams.messages} id={id}>
    {msg.text}
  </div>
</div>
```

- Streams are NOT enumerable — to filter, refetch and re-stream with `reset: true`.
- Empty states: use `<div class="hidden only:block">No items</div>` inside the stream container.
- When an assign changes content inside streamed items, you MUST re-stream those items with `stream_insert/3`.
- Never use `phx-update="append"` or `phx-update="prepend"`.

### JS Hooks

**Colocated hooks** (inline in HEEx):

```heex
<input id="phone" phx-hook=".PhoneFormat" />
<script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneFormat">
  export default {
    mounted() { /* ... */ }
  }
</script>
```

- Colocated hook names MUST start with `.` prefix.

**External hooks** (in `assets/js/`):

```javascript
const MyHook = { mounted() { /* ... */ } }
let liveSocket = new LiveSocket("/live", Socket, { hooks: { MyHook } })
```

- When using `phx-hook` with DOM management, add `phx-update="ignore"`.
- Always provide a unique DOM id with `phx-hook`.

### Server ↔ Client Events

```elixir
# Server → Client
socket = push_event(socket, "my_event", %{data: "value"})

# Client handler
this.handleEvent("my_event", data => console.log(data))

# Client → Server with reply
this.pushEvent("my_event", {one: 1}, reply => console.log(reply))
```

### Forms

```elixir
# From changeset
form = user |> Ecto.Changeset.change() |> to_form()

# From params
form = to_form(params, as: :user)
```

```heex
<.form for={@form} id="user-form" phx-change="validate" phx-submit="save">
  <.input field={@form[:name]} type="text" />
</.form>
```

### Tests

- Use `Phoenix.LiveViewTest` + `LazyHTML` for assertions.
- Test element IDs, not raw HTML text.
- Use `render_submit/2` and `render_change/2` for form tests.
- Debug selectors with:

```elixir
html = render(view)
doc = LazyHTML.from_fragment(html)
IO.inspect(LazyHTML.filter(doc, "your-selector"), label: "matches")
```

- Use `start_supervised!/1` for processes in tests.
- Never use `Process.sleep/1` — use `Process.monitor/1` + `assert_receive {:DOWN, ...}`.
- Synchronize with `:sys.get_state/1` instead of sleeping.
