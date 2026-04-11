<h1 align="center">
  <br>
  <img src=".github/assets/web-data.png" alt="Streamix" width="200">
  <br>
  Streamix — Plataforma Unificada de Streaming IPTV
  <br>
</h1>

<p align="center">
  <strong>Todos os seus provedores IPTV em uma interface cinematográfica e inteligente. TV Ao Vivo, Filmes, Séries e mais.</strong>
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Elixir-1.18+-purple?style=flat&logo=elixir" alt="Elixir" />
  <img src="https://img.shields.io/badge/Phoenix-1.8+-orange?style=flat&logo=phoenix-framework" alt="Phoenix" />
  <img src="https://img.shields.io/badge/LiveView-1.1+-blue?style=flat&logo=phoenix-framework" alt="LiveView" />
  <img src="https://img.shields.io/badge/TimescaleDB-pg17-blue?style=flat&logo=postgresql" alt="TimescaleDB" />
  <img src="https://img.shields.io/badge/Redis-7+-red?style=flat&logo=redis" alt="Redis" />
  <img src="https://img.shields.io/badge/Tailwind-v4-38bdf8?style=flat&logo=tailwindcss" alt="Tailwind CSS" />
  <img src="https://img.shields.io/badge/PWA-Ready-5A0FC8?style=flat&logo=pwa" alt="PWA Ready" />
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat&logo=appveyor" alt="License" />
  <img src="https://img.shields.io/badge/Feito%20com-Amor%20por%20Maia-red?style=flat&logo=appveyor" alt="Feito com Amor" />
</p>

<br>

<p align="center">
  <a href="#sparkles-funcionalidades">Funcionalidades</a>&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;
  <a href="#art-arquitetura">Arquitetura</a>&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;
  <a href="#computer-tecnologias">Tecnologias</a>&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;
  <a href="#package-instalação">Instalação</a>&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;
  <a href="#electric_plug-uso">Uso</a>&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;
  <a href="#memo-licença">Licença</a>
</p>

<br>

## :sparkles: Funcionalidades

### Gestão de Conteúdo

- **Agregação Multi-Provedor** — Conecte múltiplos provedores IPTV Xtream Codes (globais ou privados por usuário)
- **Sincronização em Background** — Sincronização automática de TV ao Vivo, Filmes e Séries via jobs agendados do
  Oban
- **Integração GIndex** — Transmita filmes e séries direto do Google Drive com failover multi-endpoint
- **Busca Unificada** — Pesquise em todos os provedores com fuzzy matching via `pg_trgm` e busca semântica por IA
- **Favoritos e Histórico** — Acompanhe o que você ama e retome de onde parou
- **Enriquecimento TMDB** — Metadados, pôsteres e descrições automáticos do The Movie Database
- **EPG (Guia Eletrônico de Programação)** — Informação de programação ao vivo com cache e queries de `now`/`next`

### Motor de Streaming

- **Stream Proxy** — Proxy HTTP-para-HTTPS que contorna bloqueios de conteúdo misto (HLS/MPEG-TS)
- **Stream Multiplexer** — Uma única conexão upstream servindo múltiplos clientes downstream
- **Circuit Breaker** — Resiliência estilo Netflix por provedor (estados open/half-open/closed)
- **Detecção de Formato** — Tratamento automático de formatos `m3u8` e `ts`
- **Recuperação de Erros** — Reconexão automática para streams instáveis
- **Reprodução Multi-Formato** — Streams ao vivo, filmes VOD e episódios de séries

### Inteligência Artificial

- **Busca Semântica** — Embeddings Gemini/NVIDIA NIM armazenados no Qdrant (banco vetorial)
- **Recomendações Inteligentes** — Similaridade de conteúdo, destaques e insights personalizados
- **Fuzzy Matching** — Busca por trigramas `pg_trgm` com tolerância a erros de digitação

### Experiência do Usuário

- **UI Cinematográfica** — Dark mode (padrão) + Light mode com paleta Catppuccin Latte
- **Design Responsivo** — Otimizado para Desktop, Tablet e Mobile
- **SPA com LiveView** — Navegação estilo app nativo sem recarregar página
- **Watch Party** — Assista junto em tempo real com códigos de convite
- **Suporte PWA** — Instale como app nativo em qualquer dispositivo com cache offline de metadados
- **Atalhos de Teclado** — Controles de player no estilo YouTube

### API Mobile

- **REST API v1** — API completa para clientes mobile / externos
- **Endpoints de Auth** — Registro, login e logout com autenticação por bearer token
- **Catálogo Completo** — Browse, busca, stream, favoritos, histórico e EPG
- **Telemetria** — Analytics de reprodução e monitoramento
- **Rate Limited** — Throttling por endpoint (Hammer)

### Painel Administrativo

- **Dashboard** — Visão geral e gerenciamento do sistema
- **Gestão de Planos** — Crie e administre planos de assinatura
- **Gestão de Usuários** — Controle de acesso por papel (`admin`, `moderator`, `customer`)

### Infraestrutura

- **Cache L1+L2** — ConCache (em memória) + Redis (distribuído) com write-through
- **Broadway + RabbitMQ** — Pipeline de sincronização distribuída opcional (fallback para Oban)
- **Rate Limiting** — Throttling por endpoint com Hammer
- **Criptografia AES-256-GCM** — Credenciais de provedor criptografadas em repouso
- **CSP com Nonces** — Content Security Policy dinâmica
- **Health Check** — Endpoint `/api/health` para orquestração de containers

<br>

## :art: Arquitetura

### Visão Geral

```mermaid
graph TD
    User[Usuário / Cliente]

    subgraph "Plataforma Streamix"
        LB[Phoenix Endpoint]
        LV[LiveView UI]
        API[REST API v1]
        Proxy[Stream Proxy / Multiplexer]
        CB[Circuit Breaker]
        Sync[Oban Workers]
        Broadway[Pipeline Broadway]
    end

    subgraph "Camada de Cache"
        L1[(L1: ConCache)]
        L2[(L2: Redis)]
    end

    subgraph "Camada de Dados"
        DB[(TimescaleDB pg17)]
        RMQ[RabbitMQ]
        QD[Qdrant Vector DB]
    end

    subgraph "Serviços Externos"
        P1[Provedores IPTV]
        TM[TMDB]
        GI[GIndex / GDrive]
        AI[Gemini / NVIDIA NIM]
    end

    User -->|HTTPS| LB
    LB --> LV
    LB --> API
    LB --> Proxy

    LV --> L1
    L1 -->|Miss| L2
    L2 -->|Miss| DB

    LV --> CB
    CB --> P1

    Sync --> RMQ
    RMQ --> Broadway
    Broadway -->|Bulk Insert| DB
    Sync -->|Enriquecimento| TM
    Sync -->|Embeddings| AI
    AI -->|Store| QD

    Proxy -->|HLS/TS| P1
    Sync -->|Scrape| GI
```

### Fluxo de Cache (L1 + L2)

```mermaid
sequenceDiagram
    participant C as Cliente
    participant L1 as Cache L1 (ConCache)
    participant L2 as Cache L2 (Redis)
    participant DB as TimescaleDB

    C->>L1: Buscar dado
    alt Hit no L1
        L1-->>C: Retorna do cache
    else Miss no L1
        L1->>L2: Buscar dado
        alt Hit no L2
            L2-->>L1: Retorna e popula L1
            L1-->>C: Retorna dado
        else Miss no L2
            L2->>DB: Query no banco
            DB-->>L2: Retorna e cacheia (TTL)
            L2-->>L1: Popula L1 (TTL curto)
            L1-->>C: Retorna dado
        end
    end
```

<br>

## :computer: Tecnologias

### Core

| Tecnologia                                                | Versão | Descrição                             |
|-----------------------------------------------------------|--------|---------------------------------------|
| [Elixir](https://elixir-lang.org/)                        | 1.18+  | Runtime concorrente e tolerante a falhas |
| [Phoenix](https://www.phoenixframework.org/)              | 1.8+   | Framework web em tempo real           |
| [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/) | 1.1+   | UI reativa renderizada no servidor    |
| [OTP](https://www.erlang.org/)                            | 27+    | Árvores de supervisão e fault tolerance |
| [Bandit](https://hexdocs.pm/bandit/)                      | 1.0+   | Servidor HTTP/2                       |

### Dados

| Tecnologia                                       | Descrição                                           |
|--------------------------------------------------|-----------------------------------------------------|
| [TimescaleDB](https://www.timescale.com/) (pg17) | PostgreSQL com extensões de time-series + `pg_trgm` |
| [Redis](https://redis.io/) 7+                    | Cache L2 distribuído                                |
| [Qdrant](https://qdrant.tech/)                   | Banco vetorial para busca semântica                 |
| [Ecto](https://hexdocs.pm/ecto/)                 | Queries e migrations                                |

### Processamento em Background

| Tecnologia                                | Descrição                                                 |
|-------------------------------------------|-----------------------------------------------------------|
| [Oban](https://getoban.pro/)              | Jobs em background com agendamento cron                   |
| [Broadway](https://hexdocs.pm/broadway/)  | Pipelines de dados de alto throughput (opcional, RabbitMQ)|
| [ConCache](https://hexdocs.pm/con_cache/) | Cache L1 em memória baseado em ETS                        |

### Frontend

| Tecnologia                                     | Descrição                                  |
|------------------------------------------------|--------------------------------------------|
| [Tailwind CSS](https://tailwindcss.com/) v4    | Estilização utility-first                  |
| [Catppuccin](https://catppuccin.com/)          | Paleta de cores (Latte no light mode)      |
| [Heroicons](https://heroicons.com/)            | Ícones SVG                                 |
| [hls.js](https://github.com/video-dev/hls.js/) | Reprodução de vídeo HLS                    |

### Serviços Externos

| Serviço                                                                    | Descrição                             |
|----------------------------------------------------------------------------|---------------------------------------|
| [TMDB](https://www.themoviedb.org/)                                        | Metadados e pôsteres de filmes/séries |
| [Gemini](https://ai.google.dev/) / [NVIDIA NIM](https://build.nvidia.com/) | Embeddings de IA para busca semântica |
| [GIndex](https://github.com/LeeluPrad662/G-Index)                          | Indexação de conteúdo no Google Drive |

### Qualidade e Segurança

| Ferramenta                                  | Descrição                               |
|---------------------------------------------|-----------------------------------------|
| [Hammer](https://hexdocs.pm/hammer/)        | Rate limiting                           |
| [Sobelow](https://hexdocs.pm/sobelow/)      | Análise estática de segurança (Phoenix) |
| [mix_audit](https://hexdocs.pm/mix_audit/)  | Scanner de vulnerabilidades em deps     |
| [Credo](https://hexdocs.pm/credo/)          | Qualidade e estilo de código            |
| [Dialyxir](https://hexdocs.pm/dialyxir/)    | Análise estática / success typing       |
| [ExUnit](https://hexdocs.pm/ex_unit/)       | Framework de testes                     |

<br>

## :package: Instalação

### Pré-requisitos

- **[Elixir](https://elixir-lang.org/install.html)** 1.18+ (com OTP 27+)
- **[Docker](https://www.docker.com/)** (para os serviços de infraestrutura)

### Início Rápido

1. **Clone e entre no diretório**

```bash
git clone https://github.com/gabrielmaialva33/streamix.git
cd streamix
```

2. **Suba a infraestrutura**

```bash
docker compose up -d  # TimescaleDB, Redis, RabbitMQ, Qdrant
```

3. **Configure o ambiente**

```bash
cp .env.example .env
# Edite .env com suas credenciais (provedor IPTV, chave da API TMDB, etc.)
```

Se `TEST_DATABASE_URL` não estiver definido, o ambiente de teste deriva
automaticamente uma base irmã `*_test` a partir de `DATABASE_URL`.

4. **Setup e execução**

```bash
mix setup    # deps, banco de dados e assets
mix phx.server
```

5. **Abra** [http://localhost:4000](http://localhost:4000)

### Docker em Produção

Imagem pré-construída no GHCR:

```bash
docker pull ghcr.io/gabrielmaialva33/streamix:latest

docker run -p 4000:4000 \
  -e DATABASE_URL="ecto://user:pass@host/streamix" \
  -e TEST_DATABASE_URL="ecto://user:pass@host/streamix_test" \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  ghcr.io/gabrielmaialva33/streamix:latest
```

Ou build local:

```bash
docker build -t streamix .
docker run -p 4000:4000 -e DATABASE_URL="..." -e SECRET_KEY_BASE="..." streamix
```

<br>

## :electric_plug: Uso

### Primeiros Passos

1. **Registre** uma conta em `/register`
2. Vá em **Provedores** e adicione suas credenciais Xtream Codes
3. O Streamix sincroniza canais, filmes e séries automaticamente em background
4. Navegue, pesquise e assista o conteúdo de todos os seus provedores

### Tipos de Conteúdo

- **TV Ao Vivo** — Navegue por categoria, pesquise canais, clique pra assistir
- **Filmes** — Biblioteca VOD com metadados e pôsteres do TMDB
- **Séries** — Séries completas com temporadas e episódios
- **GIndex** — Conteúdo do Google Drive (filmes, séries, anime)

### Watch Party

Crie uma watch party pra sincronizar a reprodução com amigos usando códigos de convite.

### Mobile / Players Externos

Use a REST API em `/api/v1/` com autenticação por bearer token. Consulte a documentação da API pros endpoints
disponíveis.

### PWA

Instale o Streamix como app nativo:

- **Chrome/Edge**: clique no ícone de instalação na barra de endereço
- **Android**: Menu > "Adicionar à tela inicial"
- **iOS Safari**: Compartilhar > "Adicionar à Tela de Início"

<br>

## :handshake: Contribuindo

Contribuições são bem-vindas! Fique à vontade pra mandar um Pull Request.

1. Faça um fork do projeto
2. Crie sua branch de feature (`git checkout -b feature/RecursoIncrivel`)
3. Commit suas mudanças (`git commit -m 'feat: adiciona recurso incrível'`)
4. Rode `mix precommit` antes de abrir o PR
5. Push na branch (`git push origin feature/RecursoIncrivel`)
6. Abra um Pull Request

<br>

## :memo: Licença

Este projeto está sob a licença **MIT**. Veja [LICENSE](./LICENSE) pra detalhes.

<br>

## :busts_in_silhouette: Autor

<p align="center">
  <img src="https://avatars.githubusercontent.com/u/26732067" alt="Maia" width="100">
</p>

Feito com Amor por **Maia**

- Email: [gabrielmaialva33@gmail.com](mailto:gabrielmaialva33@gmail.com)
- GitHub: [@gabrielmaialva33](https://github.com/gabrielmaialva33)

<br>

<p align="center">
  <img src="https://raw.githubusercontent.com/gabrielmaialva33/gabrielmaialva33/master/assets/gray0_ctp_on_line.svg?sanitize=true" />
</p>

<p align="center">
  <strong>Streamix v1.3.0 — Onde o entretenimento encontra a tecnologia.</strong>
</p>

<p align="center">
  &copy; 2024-2026 <a href="https://github.com/gabrielmaialva33/" target="_blank">Maia</a>
</p>
