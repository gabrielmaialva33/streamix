[
  import_deps: [:ecto, :ecto_sql, :open_api_spex, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,credo_checks,lib,rel,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ]
]
