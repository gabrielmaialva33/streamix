# Streamix

Plataforma de streaming em Phoenix + LiveView que agrega multiplos provedores Xtream Codes em uma unica aplicacao web
e API REST. O Streamix suporta canais ao vivo, filmes, series, favoritos, historico, progresso de reproducao, acesso
premium, watch parties e busca / recomendacoes com IA quando configuradas.

[English](README.md)

## O Que Existe Neste Repositorio

Este repositorio contem:

- o backend Phoenix
- o cliente web em LiveView
- o stream proxy e o fluxo de stream tokens assinados
- a API REST para clientes mobile / TV
- as integracoes opcionais com IA, Redis, Qdrant, RabbitMQ e GIndex

Ele **nao** contem mais o frontend antigo de TV que ja foi extraido para outro repositorio.

## Resumo de Funcionalidades

### Produto principal

- Agregacao de multiplos provedores Xtream Codes
- Provedor global opcional compartilhado entre usuarios
- Ingestao opcional via GIndex para catalogos baseados em Google Drive
- TV ao vivo, filmes, series, temporadas e episodios
- Favoritos, historico e progresso de reproducao
- Sincronizacao de EPG com consultas de now/next
- Planos, assinaturas e bloqueio premium de reproducao
- Painel administrativo para usuarios e planos

### Playback e entrega

- Stream URLs assinadas para canais, filmes e episodios
- Proxy Phoenix para evitar mixed content e esconder credenciais
- Multiplexador de canais ao vivo para compartilhar conexoes upstream
- Suporte a HLS, MPEG-TS e fluxos orientados a AVPlayer
- Circuit breaker por provedor para reduzir falhas em cascata

### Tempo real e UX

- Watch parties com reproducao sincronizada, presence e chat
- UI responsiva em LiveView
- Manifest e service worker de PWA
- Hooks de sincronizacao offline para favoritos e historico
- Toggle de tema com dark mode por padrao

### Superficies opcionais de IA

- Embeddings via Gemini ou NVIDIA
- Busca semantica com Qdrant
- Recomendacoes de conteudo similar
- Perfil de gosto do usuario e secoes personalizadas na home

Se os servicos de IA nao estiverem configurados, o Streamix faz fallback para busca textual onde isso faz sentido.

## Stack

- Elixir `~> 1.18`
- OTP 27
- Phoenix `~> 1.8.2`
- Phoenix LiveView `~> 1.1.0`
- Ecto SQL `~> 3.13`
- TimescaleDB / PostgreSQL 17
- Redis 7
- Qdrant (opcional)
- RabbitMQ 4 + Broadway (opcional)
- Oban 2.18
- Req + Finch
- Tailwind CSS v4
- esbuild
- pacotes npm em `assets/`

## Estrutura do Repositorio

```text
lib/streamix/
  access/        permissoes e grants
  accounts/      usuarios, papeis, tokens, settings, rastreio de IP
  ai/            embeddings, Qdrant, busca semantica, analiticos do usuario
  billing/       planos e assinaturas
  iptv/          provedores, sync, catalogo, EPG, stream proxy, GIndex
  library/       referencias compartilhadas de conteudo
  queue/         caminho opcional com RabbitMQ + Broadway
  watch_party/   rooms, participantes, mensagens, room server
  workers/       workers do Oban

lib/streamix_web/
  controllers/   HTML, stream proxy, health e API v1
  live/          landing, auth, catalogo, admin, watch party, providers
  components/    layouts e UI reutilizavel
  plugs/         CORS, CSP nonce, API key auth, rate limiting

assets/
  css/app.css
  js/app.js
  js/hooks/
```

## Inicio Rapido

### Requisitos

- Docker
- Elixir 1.18+
- OTP 27+
- Node.js 20+ e npm

### 1. Suba a infraestrutura

```bash
docker compose up -d
```

O compose sobe:

- TimescaleDB / PostgreSQL 17
- Redis
- RabbitMQ
- Qdrant

RabbitMQ e Qdrant sao opcionais em runtime, mas o compose os inclui no ambiente local.

### 2. Configure o ambiente

```bash
cp .env.example .env
```

Valores minimos que voce precisa definir antes do `mix setup`:

- `ADMIN_PASSWORD`
- `PROVIDER_ENCRYPTION_KEY`

Variaveis importantes:

- `DATABASE_URL` - por padrao `ecto://streamix:streamix@localhost/streamix_dev`
- `TEST_DATABASE_URL` - opcional; se faltar, e inferido a partir de `DATABASE_URL`
- `REDIS_URL`
- `GLOBAL_PROVIDER_*` - provedor global opcional
- `GINDEX_ENABLED` / `GINDEX_URL` - integracao opcional com GIndex
- `TMDB_API_TOKEN` - enriquecimento opcional com TMDB
- `GEMINI_API_KEY` ou `NVIDIA_API_KEY` - embeddings opcionais
- `QDRANT_URL` - necessario para busca semantica
- `RABBITMQ_ENABLED` - caminho opcional com Broadway
- `API_KEYS` - chaves da API para clientes externos

Em producao, voce tambem precisa de:

- `SECRET_KEY_BASE`
- `LIVE_VIEW_SIGNING_SALT`
- `PHX_HOST`

### 3. Instale as dependencias de frontend

```bash
cd assets && npm ci && cd ..
```

`assets/node_modules` e ignorado, e o `mix setup` nao roda `npm ci` automaticamente.

### 4. Prepare a aplicacao

```bash
mix setup
```

O `mix setup` executa:

- `mix deps.get`
- `mix ecto.setup`
- `mix assets.setup`
- `mix assets.build`

Como `ecto.setup` roda seeds, um `ADMIN_PASSWORD` ausente faz o setup falhar.

### 5. Rode o Streamix

```bash
mix phx.server
```

Abra [http://localhost:4000](http://localhost:4000).

## Comandos Uteis

```bash
mix test
mix test path/to/test.exs
mix test path/to/test.exs:42

mix credo --strict
mix quality
mix precommit

mix ecto.migrate
mix ecto.reset

mix assets.build
mix assets.deploy
```

## Superficies Principais

### Rotas web

- `/` landing page
- `/plans`
- `/login`, `/register`, `/settings`
- `/browse`, `/browse/movies`, `/browse/series`
- `/providers`, `/providers/:provider_id/...`
- `/favorites`, `/history`
- `/gindex/...`
- `/party`, `/party/:invite_code`, `/party/:invite_code/watch`
- `/watch/:type/:id`
- `/admin`, `/admin/plans`, `/admin/users`

### API REST

Os endpoints principais ficam em `/api/v1`:

- `/auth/register`, `/auth/login`, `/auth/logout`, `/auth/me`
- `/catalog/...`
- `/search/...`
- `/recommendations/...`
- `/favorites`
- `/history`
- `/epg/...`
- `/telemetry/playback`
- `/providers`

O endpoint de healthcheck e `GET /api/health`.

## Notas de Arquitetura

- `Streamix.Iptv.XtreamClient` e a porta unica para chamadas HTTP aos provedores Xtream.
- `Streamix.Iptv.Gindex.Client` + `EndpointManager` fazem selecao de endpoint e controle de pacing do GIndex.
- `Streamix.Cache` entrega cache L1 em ConCache + L2 em Redis.
- `Streamix.AI.SemanticSearch` e `Streamix.AI.UserAnalytics` alimentam as features opcionais de IA.
- `Streamix.WatchParty.RoomServer` coordena o estado ao vivo das watch parties.
- `StreamixWeb.StreamToken` assina as stream URLs para nao expor credenciais upstream.

## Imagem Docker

O repositorio publica:

```text
ghcr.io/gabrielmaialva33/streamix:latest
```

O workflow atual do GitHub Actions faz build e push da imagem Docker em pushes para `master`.

## Contribuicao, Seguranca e Licenca

- Contribuicao: [CONTRIBUTING.md](CONTRIBUTING.md)
- Seguranca: [SECURITY.md](SECURITY.md)
- Regras de agente / repositorio: [AGENTS.md](AGENTS.md)
- Licenca: [MIT](LICENSE)
