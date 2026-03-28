# Streamix Impecavel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Corrigir bugs reais, alinhar as principais convencoes Elixir/Phoenix/HEEx, reduzir hotspots de complexidade e deixar `mix precommit` verde.

**Architecture:** O trabalho sera executado por fases orientadas a risco. Primeiro corrigir contratos quebrados, ownership, concorrencia e bugs concretos. Depois endurecer testes, alinhar convencoes do ecossistema e reduzir complexidade dos hotspots sem reescrever desnecessariamente o sistema.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, Oban, Req, ConCache, Redix, ExUnit, Credo

---

### Task 1: Corrigir ownership e contrato do provider

**Files:**
- Modify: `lib/streamix/iptv/provider.ex`
- Modify: `lib/streamix/iptv/providers.ex`
- Modify: `lib/streamix_web/live/providers/provider_form_component.ex`
- Test: `test/streamix/iptv/providers_test.exs`

- [ ] **Step 1: Write the failing tests**

Add tests covering:
- `Provider.changeset/2` nao deve aceitar `user_id` via `cast`
- `Providers.create/2` ou API equivalente deve aplicar `user_id` no contexto, nao no params map
- `ProviderFormComponent` nao deve depender de injetar ownership pelo form payload

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/streamix/iptv/providers_test.exs`
Expected: FAIL mostrando que `user_id` ainda entra pelo changeset ou que a API publica ainda depende disso

- [ ] **Step 3: Implement minimal fix**

Implementation targets:
- remover `:user_id` de `@all_fields` em `Streamix.Iptv.Provider`
- adicionar API no contexto para criar provider com ownership aplicado pelo servidor
- atualizar `ProviderFormComponent` para usar a nova API sem `Map.put("user_id", ...)`

- [ ] **Step 4: Run focused tests**

Run: `mix test test/streamix/iptv/providers_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/streamix/iptv/provider.ex lib/streamix/iptv/providers.ex lib/streamix_web/live/providers/provider_form_component.ex test/streamix/iptv/providers_test.exs
git commit -m "fix: harden provider ownership flow"
```

### Task 2: Corrigir mismatch de params e bug do worker de sync

**Files:**
- Modify: `lib/streamix_web/live/providers/provider_list_live.ex`
- Modify: `lib/streamix/workers/sync_provider_worker.ex`
- Test: `test/streamix/workers/sync_provider_worker_test.exs`
- Test: `test/streamix_web/live/providers/provider_list_live_test.exs`

- [ ] **Step 1: Write the failing tests**

Add tests covering:
- rota de edit de provider deve carregar usando `provider_id`
- `SyncProviderWorker` deve publicar contagens usando os campos reais do schema

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/streamix/workers/sync_provider_worker_test.exs test/streamix_web/live/providers/provider_list_live_test.exs`
Expected: FAIL por lookup incorreto de params e/ou payload de contagem incorreto

- [ ] **Step 3: Implement minimal fix**

Implementation targets:
- ajustar `apply_action/3` para consumir `%{"provider_id" => id}`
- corrigir `live_count` para `live_channels_count`
- revisar nomes de chaves do payload para manter consistencia entre worker e LiveView

- [ ] **Step 4: Run focused tests**

Run: `mix test test/streamix/workers/sync_provider_worker_test.exs test/streamix_web/live/providers/provider_list_live_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/streamix_web/live/providers/provider_list_live.ex lib/streamix/workers/sync_provider_worker.ex test/streamix/workers/sync_provider_worker_test.exs test/streamix_web/live/providers/provider_list_live_test.exs
git commit -m "fix: align provider params and sync payloads"
```

### Task 3: Remover atom dinamico e endurecer endpoint manager

**Files:**
- Modify: `lib/streamix/iptv/gindex/endpoint_manager.ex`
- Test: `test/streamix/iptv/gindex/endpoint_manager_test.exs`

- [ ] **Step 1: Write the failing tests**

Add tests covering:
- configuracao dinamica de endpoints nao cria atom novo em runtime
- manager continua retornando endpoints ordenados e enderecaveis

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/streamix/iptv/gindex/endpoint_manager_test.exs`
Expected: FAIL por expectativa nova de chaves/identificadores ou ausencia de teste existente

- [ ] **Step 3: Implement minimal fix**

Implementation targets:
- substituir `String.to_atom/1` por identificador string ou tupla estavel
- ajustar lookup e serializacao de status conforme o novo identificador

- [ ] **Step 4: Run focused tests**

Run: `mix test test/streamix/iptv/gindex/endpoint_manager_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/streamix/iptv/gindex/endpoint_manager.ex test/streamix/iptv/gindex/endpoint_manager_test.exs
git commit -m "fix: remove dynamic atoms from gindex endpoints"
```

### Task 4: Substituir fire-and-forget critico por execucao supervisionada

**Files:**
- Modify: `lib/streamix/application.ex`
- Modify: `lib/streamix/accounts/ip_tracker.ex`
- Modify: `lib/streamix/application.ex` child tree if needed
- Test: `test/streamix/accounts/ip_tracker_test.exs`
- Test: `test/streamix/application_test.exs`

- [ ] **Step 1: Write the failing tests**

Add tests covering:
- `IpTracker.log_access_async/2` executa por `Task.Supervisor` ou mecanismo supervisionado equivalente
- bootstrap de providers nao depende de `Task.start/1` sem supervisao

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/streamix/accounts/ip_tracker_test.exs test/streamix/application_test.exs`
Expected: FAIL por ausencia de supervisao explicita ou comportamento nao observavel

- [ ] **Step 3: Implement minimal fix**

Implementation targets:
- adicionar `Task.Supervisor` dedicado ou mover inicializacao para job/processo supervisionado
- trocar `Task.start/1` por `Task.Supervisor.start_child/2` ou alternativa OTP consistente

- [ ] **Step 4: Run focused tests**

Run: `mix test test/streamix/accounts/ip_tracker_test.exs test/streamix/application_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/streamix/application.ex lib/streamix/accounts/ip_tracker.ex test/streamix/accounts/ip_tracker_test.exs test/streamix/application_test.exs
git commit -m "refactor: supervise background side effects"
```

### Task 5: Endurecer testes com sincronizacao deterministica

**Files:**
- Modify: `test/streamix/cache_test.exs`
- Modify: `test/streamix/iptv/xtream_circuit_breaker_test.exs`
- Modify: `test/streamix/iptv_test.exs`
- Modify: supporting modules only if needed for testability

- [ ] **Step 1: Write or adjust tests to use deterministic signals**

Focus:
- substituir `Process.sleep/1` por sinais de estado, mensagens ou timeout controlado quando possivel
- manter sleeps apenas onde o comportamento depende de TTL real e nao houver melhor seam

- [ ] **Step 2: Run targeted tests to observe failures or flakiness**

Run: `mix test test/streamix/cache_test.exs test/streamix/iptv/xtream_circuit_breaker_test.exs test/streamix/iptv_test.exs`
Expected: identificar trechos ainda frageis

- [ ] **Step 3: Implement minimal fixes**

Implementation targets:
- usar `:sys.get_state/1`, `assert_receive`, monitoramento ou hooks de teste
- introduzir seam de clock apenas onde for realmente necessario

- [ ] **Step 4: Re-run targeted tests**

Run: `mix test test/streamix/cache_test.exs test/streamix/iptv/xtream_circuit_breaker_test.exs test/streamix/iptv_test.exs`
Expected: PASS e menor flakiness

- [ ] **Step 5: Commit**

```bash
git add test/streamix/cache_test.exs test/streamix/iptv/xtream_circuit_breaker_test.exs test/streamix/iptv_test.exs
git commit -m "test: reduce flaky timing dependencies"
```

### Task 6: Alinhar HEEx e convencoes Phoenix mais relevantes

**Files:**
- Modify: `lib/streamix_web/components/layouts/app.html.heex`
- Modify: `lib/streamix_web/live/home_live.ex`
- Modify: `lib/streamix_web/live/favorites_live.ex`
- Modify: `lib/streamix_web/live/history_live.ex`
- Modify: representative HEEx-heavy files flagged by search

- [ ] **Step 1: Add or update regression coverage where templates are behavior-sensitive**

Focus on areas where markup changes could break LiveView selectors or interactions.

- [ ] **Step 2: Run focused LiveView tests**

Run: `mix test test/streamix_web/live`
Expected: baseline before template cleanup

- [ ] **Step 3: Implement cleanup**

Implementation targets:
- trocar `<!-- ... -->` por `<%!-- ... --%>` em HEEx
- preferir listas de classes em vez de concatenacao manual onde melhorar clareza
- remover trechos que conflitam com guidelines Phoenix do projeto

- [ ] **Step 4: Re-run focused LiveView tests**

Run: `mix test test/streamix_web/live`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/streamix_web/components/layouts/app.html.heex lib/streamix_web/live/home_live.ex lib/streamix_web/live/favorites_live.ex lib/streamix_web/live/history_live.ex
git commit -m "refactor: align heex templates with phoenix conventions"
```

### Task 7: Refatorar hotspots de complexidade de infraestrutura

**Files:**
- Modify: `lib/streamix/iptv/xtream_client.ex`
- Modify: `lib/streamix_web/stream_token.ex`
- Modify: `lib/streamix_web/player_helpers.ex`
- Test: targeted tests for each modified module

- [ ] **Step 1: Add characterization tests where behavior is under-specified**

Cover critical paths:
- retries e erro categorizado em `XtreamClient`
- verificacao e expiracao em `StreamToken`
- resolucao de next episode e fallback de player helpers

- [ ] **Step 2: Run targeted tests to verify RED where behavior changes**

Run: `mix test test/streamix/iptv test/streamix_web`
Expected: failing tests for extracted edge cases where new behavior/assertions are introduced

- [ ] **Step 3: Refactor in small steps**

Implementation targets:
- extrair funcoes privadas para branches de erro e retry
- reduzir nested conditionals
- isolar parse/validation from side effects

- [ ] **Step 4: Re-run targeted tests**

Run: `mix test test/streamix/iptv test/streamix_web`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/streamix/iptv/xtream_client.ex lib/streamix_web/stream_token.ex lib/streamix_web/live/player_helpers.ex test/streamix test/streamix_web
git commit -m "refactor: reduce infrastructure hotspot complexity"
```

### Task 8: Refatorar hotspots de complexidade de recomendacao/AI

**Files:**
- Modify: `lib/streamix/ai/user_analytics.ex`
- Test: `test/streamix/ai/user_analytics_test.exs` or create it if absent

- [ ] **Step 1: Add characterization tests**

Cover:
- perfil de usuario
- recomendacoes
- filtros personalizados
- fallbacks quando embeddings/semantic search nao estao disponiveis

- [ ] **Step 2: Run tests to verify RED for new edges**

Run: `mix test test/streamix/ai/user_analytics_test.exs`
Expected: FAIL until behavior is captured and refactor seams exist

- [ ] **Step 3: Refactor incrementally**

Implementation targets:
- separar queries, agregacao de perfil e ranking
- reduzir profundidade de branching
- substituir pipelines redundantes por helpers pequenos e previsiveis

- [ ] **Step 4: Re-run targeted tests**

Run: `mix test test/streamix/ai/user_analytics_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/streamix/ai/user_analytics.ex test/streamix/ai/user_analytics_test.exs
git commit -m "refactor: simplify user analytics pipeline"
```

### Task 9: Convergir com Credo nos itens relevantes restantes

**Files:**
- Modify: files flagged by Credo after prior tasks

- [ ] **Step 1: Run Credo and capture remaining actionable issues**

Run: `mix credo suggest --strict`
Expected: narrowed list after previous fixes

- [ ] **Step 2: Fix remaining high-signal items**

Focus:
- functions too complex still in active scope
- nested modules aliasing where it improves clarity
- missing `@moduledoc`
- obvious inefficiencies and redundant clauses

- [ ] **Step 3: Re-run Credo**

Run: `mix credo suggest --strict`
Expected: no remaining high-signal issues in touched areas, ideally clean overall

- [ ] **Step 4: Commit**

```bash
git add lib test
git commit -m "refactor: resolve remaining credo issues"
```

### Task 10: Verificacao final completa

**Files:**
- Modify: any file needed to fix failures found here

- [ ] **Step 1: Format**

Run: `mix format`
Expected: exit 0

- [ ] **Step 2: Run focused full checks**

Run: `mix credo suggest --strict`
Expected: acceptable output or clean run

- [ ] **Step 3: Run full test suite**

Run: `mix test`
Expected: all tests pass

- [ ] **Step 4: Run final gate**

Run: `mix precommit`
Expected: exit 0, warnings-as-errors compile, format, credo and tests all green

- [ ] **Step 5: Final commit**

```bash
git add lib test docs/superpowers/specs/2026-03-28-streamix-impecavel-design.md docs/superpowers/plans/2026-03-28-streamix-impecavel.md
git commit -m "chore: make streamix codebase rigorous and clean"
```

