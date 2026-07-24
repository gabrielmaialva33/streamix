defmodule Streamix.Repo.Migrations.AddSubtitlePreferencesToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :subtitles_enabled, :boolean, null: false, default: true
      add :subtitle_language, :string, null: false, default: "pt-BR"
      add :subtitle_offset_ms, :integer, null: false, default: 0
    end

    create constraint(:users, :subtitle_offset_ms_range,
             check: "subtitle_offset_ms BETWEEN -600000 AND 600000"
           )
  end
end
