defmodule Streamix.Repo.Migrations.CreateTitleTags do
  use Ecto.Migration

  # One row per title, not per provider copy: copies share a `variant_key`
  # (`tmdb:<id>` when matched), and a title is classified once for all of
  # them. Slugs come from `Streamix.Iptv.Tags.Vocabulary`; rows classified
  # against an older `vocabulary_version` are classified again.
  def change do
    create table(:title_tags) do
      add :kind, :string, null: false
      add :variant_key, :string, size: 512, null: false
      add :subgenres, {:array, :string}, null: false, default: []
      add :moods, {:array, :string}, null: false, default: []
      add :pace, :string
      add :eras, {:array, :string}, null: false, default: []
      add :settings, {:array, :string}, null: false, default: []
      add :audience, :string
      add :themes, {:array, :string}, null: false, default: []
      add :origins, {:array, :string}, null: false, default: []
      add :vocabulary_version, :integer, null: false
      add :model, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:title_tags, [:kind, :variant_key])

    for facet <- [:subgenres, :moods, :eras, :settings, :themes, :origins] do
      create index(:title_tags, [facet], using: :gin)
    end
  end
end
