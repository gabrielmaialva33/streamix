# Enriquecimento de metadados do catálogo

Como uma linha do catálogo ganha sinopse, nota, tagline, classificação, trailer
e arte. São dois estágios separados, em dois workers, e por muito tempo só o
primeiro existia — o que explica um catálogo com 148 mil filmes e sinopse em
menos da metade.

## Os dois estágios

| Estágio | Worker | Pergunta que responde | Custo |
|---|---|---|---|
| 1. casamento | `Gindex.BackfillTmdbWorker` | "que título do TMDB é este arquivo?" | 1 busca TMDB |
| 2. leitura | `TmdbDetailsWorker` | "o que o TMDB diz sobre este id?" | 1 leitura TMDB (cache Redis 24h) |

O estágio 1 escreve `tmdb_id` e carimba `tmdb_searched_at`. O estágio 2 escreve
o conteúdo e carimba `tmdb_details_at`. Os dois carimbos existem porque
respondem coisas diferentes: **procurei** não é **li**.

O estágio 2 não reimplementa enriquecimento nenhum. Cada linha passa por
`Catalog.fetch_movie_info/1` / `fetch_series_info/1`, exatamente o caminho que
a página de detalhe dispara quando alguém abre o título. O worker só decide
*quais* linhas passam por lá, e em que ritmo.

## O que estava quebrado

Duas lacunas independentes, medidas em produção em 4 de setembro de 2026:

**16.303 linhas casadas e nunca lidas.** O backfill de pôster resolvia o
`tmdb_id`, gravava a arte, carimbava `tmdb_searched_at` e parava. Nunca chamava
o endpoint de detalhes. 14.558 filmes e 1.745 séries seguravam um `tmdb_id`
e renderizavam sem sinopse.

**56.050 linhas nunca casadas.** O estágio 1 selecionava por
`gindex_path IS NOT NULL`. O catálogo xtream inteiro — 55.497 filmes — nunca
tinha passado por um matcher. Sondando `get_vod_info` do provider para três
deles, o motivo de nada mais conseguir identificá-los:

```
keys: [..., "plot", "rating", "tmdb_id", ...]   plot_len: 0   rating: 0   tmdb_id: 0
```

Os campos existem no payload e vêm vazios em todas as linhas. O provider não é
fonte de metadado; é fonte de stream.

Cobertura de sinopse por origem, antes:

| origem | filmes | com sinopse |
|---|---|---|
| torrent | 76.939 | 99,3% |
| gindex | 16.353 | 0,1% |
| xtream | 55.509 | 0,0% |

**8.571 filmes exibindo a string de release como título.** A UI mostra
`title || name`, e 16.309 filmes não têm `title` nenhum — então cai no `name`,
que para 8.571 deles é `A Jornada de Vivo 2021 1080p NF WEB-DL DDP5 1 Atmos
x264-PiA`. 7.899 desses já tinham `tmdb_id`: o título correto vinha na mesma
resposta que já buscávamos e era descartado.

O parser agora devolve `:_tmdb_title`, uma chave privada que só vira `:title`
quando a linha não tem nenhum. Provider ganha do TMDB no catálogo dele, então
um `:title` explícito nos attrs sempre vence.

## Idempotência

`tmdb_details_at` existe porque *"o plot ainda está vazio"* não serve de marca.
O TMDB não tem sinopse em pt-BR para uma cauda longa de títulos, e essas linhas
voltariam para a fila toda noite, para sempre.

A linha é carimbada assim que o enriquecimento **completa**, com ou sem
resposta útil. Só volta quem foi carimbado há mais de 30 dias e continua
incompleto — sem sinopse **ou** sem título —, o que cobre uma falha transitória
do TMDB sem transformar a cauda numa esteira. Um crash ou timeout deixa a linha sem carimbo, então ela é
repescada na passada seguinte.

O índice parcial carrega o mesmo predicado, então encolhe até sumir conforme a
fila drena:

```sql
create index movies_tmdb_details_pending_idx on movies (id)
  where tmdb_details_at is null and tmdb_id is not null
    and (plot is null or plot = '' or title is null or title = '');
```

## Duas regras que a ampliação do estágio 1 forçou

**Arte se preenche, nunca se substitui.** Linhas gindex não têm pôster próprio,
então escrever direto era seguro lá. 55.067 das linhas xtream que o sweep passou
a visitar já carregam um pôster do provider.

**Título adulto fica fora**, pelo flag curado `categories.is_adult`. O TMDB não
os tem, então todos os 8.047 são miss garantido — e `requeue_stale_misses/0`
devolveria os 8.047 para a fila toda semana, indefinidamente. Pior: uma busca
que passe do limiar mesmo assim gravaria a sinopse e o pôster de um filme real
em cima de um deles.

Casar por palavra no título foi descartado depois de medir: o flag cobre as
8.047 linhas, e o regex acrescentaria exatamente **uma** — um `^xxx ` que tem
tanta chance de ser o filme do Vin Diesel quanto qualquer outra coisa.

## Cadência

| Horário | Worker |
|---|---|
| 03:00 | sync gindex |
| 03:30 | estágio 1 (casamento) |
| 04:00 | backfill de galeria de arte |
| 04:45 | estágio 2 (leitura de detalhes) |

04:45 fica livre do matcher e do backfill de arte, que dividem o pool de tokens
TMDB. O estágio 2 roda na fila `tmdb_details` com concorrência 2, e cada job
processa dois enriquecimentos em paralelo — pico de 4 requisições, dentro do que
o pacer do gindex libera.

## Rodando na mão

Drenar mais rápido que o cron, de dentro do release:

```elixir
# estágio 2 — o backlog inteiro, lotes espaçados de 4s
Streamix.Workers.TmdbDetailsWorker.enqueue_pending(limit: 20_000, delay: 4)
#=> %{movie: %{rows: 14548, batches: 582}, series: %{rows: 1745, batches: 70}}

# estágio 1 — casamento; o loop de continuação encadeia sozinho
%{} |> Streamix.Workers.Gindex.BackfillTmdbWorker.new() |> Oban.insert()
```

Acompanhando:

```sql
select count(*) filter (where tmdb_details_at is not null)              as lidos,
       count(*) filter (where tmdb_details_at is not null
                          and plot is not null and plot <> '')          as enriquecidos
from movies;
```

Medido em produção com 10 filmes: 1,8 s para o lote, 7 com sinopse. No primeiro
drenar real, 63 de 68 (93%) — as que ficam de fora são as sem tradução pt-BR, e
o carimbo garante que não sejam perguntadas de novo.
