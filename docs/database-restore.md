# Restaurando o banco de produção

Procedimento verificado em 4 de setembro de 2026, restaurando um dump real de
produção num container descartável: zero erros e todas as contagens de linha
idênticas à origem.

O banco usa TimescaleDB, então um `pg_restore` comum **falha**. Duas armadilhas,
ambas reproduzidas antes de escrever este documento:

1. A imagem do TimescaleDB instala a extensão mais nova no boot, mas o dump
   carrega a versão que produção usava. `timescaledb_post_restore()` aborta com
   `catalog version mismatch`. O banco de destino precisa instalar a versão
   **gravada no arquivo `.meta` do backup**, não a padrão da imagem.
2. `pg_restore --jobs` reordena as tabelas de catálogo do próprio TimescaleDB e
   gera violações de chave estrangeira. A restauração tem que ser serial.

## Onde estão os backups

Em `/opt/streamix/backups` na VPS, com três arquivos por backup:

| Arquivo | Conteúdo |
|---|---|
| `streamix-<stamp>.dump` | dump custom format, comprimido |
| `globals-<stamp>.sql` | roles e permissões do cluster |
| `streamix-<stamp>.meta` | versão do TimescaleDB, imagem, tamanho, contagem de entradas |

O script `scripts/backup-database.sh` gera os três, recusa um dump menor que o
piso configurado, valida que o `pg_restore --list` consegue ler o índice, e
mantém os 14 mais recentes.

**Backups não são automáticos.** Não há timer nem passo de deploy que os gere:
por decisão do operador, rodar é manual. Na VPS o script está instalado em
`/opt/streamix/bin/backup-database.sh`. Antes de qualquer migration com risco
de perda de dado, rode:

```bash
ssh root@<vps> /opt/streamix/bin/backup-database.sh
```

A retenção só é aplicada quando o script roda, então os dumps existentes ficam
onde estão até a próxima execução.

## Restaurando

```bash
STAMP=20260904T132215Z                       # o backup escolhido
DUMP=/opt/streamix/backups/streamix-$STAMP.dump
TS_VERSION=$(grep timescaledb_version /opt/streamix/backups/streamix-$STAMP.meta | cut -d= -f2)

# 1. Container de destino (aqui, descartável para teste)
docker run -d --name pg-restore \
  -e POSTGRES_USER=streamix -e POSTGRES_PASSWORD=temp -e POSTGRES_DB=postgres \
  timescale/timescaledb:2.29.2-pg17

# 2. Banco vazio, com a extensão na versão do dump
docker exec pg-restore psql -U streamix -d postgres -c 'create database streamix_prod'
docker exec pg-restore psql -U streamix -d streamix_prod \
  -c 'drop extension if exists timescaledb cascade'
docker exec pg-restore psql -U streamix -d streamix_prod \
  -c "create extension timescaledb version '$TS_VERSION'"

# 3. Roles
docker cp /opt/streamix/backups/globals-$STAMP.sql pg-restore:/tmp/globals.sql
docker exec pg-restore psql -U streamix -d postgres -f /tmp/globals.sql

# 4. Restauração, obrigatoriamente serial
docker exec pg-restore psql -U streamix -d streamix_prod -c 'select timescaledb_pre_restore()'
docker cp "$DUMP" pg-restore:/tmp/r.dump
docker exec pg-restore pg_restore -U streamix -d streamix_prod --no-owner /tmp/r.dump
docker exec pg-restore psql -U streamix -d streamix_prod -c 'select timescaledb_post_restore()'
```

Confira contando linhas nas tabelas que importam e comparando com a origem:

```sql
select 'users', count(*) from users
union all select 'subscriptions', count(*) from subscriptions
union all select 'providers', count(*) from providers
union all select 'catalog_items', count(*) from catalog_items
union all select 'watch_progress', count(*) from watch_progress
order by 1;
```

## Onde o cluster fica

`/var/lib/postgresql/data`, no volume nomeado `streamix_streamix_postgres_data`.

Até 4 de setembro de 2026 o compose montava esse volume em
`/home/postgres/pgdata/data`, um caminho que a imagem nunca usa. O cluster real
vivia num volume anônimo, invisível para qualquer checagem baseada em
`docker volume ls`, e um `docker compose down` seguido de `up` teria subido um
banco vazio. Os dados foram copiados para o volume nomeado com verificação de
checksum por arquivo, e o volume anônimo `01fbf6aa8f…` ficou preservado como
rollback. Ele pode ser removido depois que alguns backups diários tiverem sido
gerados e verificados.
