# Streamix Impecavel Design

## Objetivo

Levar o projeto a um estado tecnicamente rigoroso e idiomatico para Elixir/Phoenix, sem parar em limpeza superficial. O resultado esperado e:

- bugs concretos corrigidos
- fluxos sensiveis endurecidos
- convencoes Elixir, Ecto, Phoenix e HEEx alinhadas
- hotspots de complexidade reduzidos
- testes mais confiaveis
- `mix precommit` verde no fim

## Definicao de "impecavel"

Neste trabalho, "impecavel" significa:

1. corrigir bugs funcionais e inconsistencias de contrato ja identificados
2. remover praticas que fogem claramente das convencoes da linguagem ou do ecossistema
3. atacar os principais problemas estruturais que hoje elevam risco de manutencao
4. manter ou ampliar cobertura de testes para as correcoes
5. validar o estado final com verificacao completa, nao por inferencia

Nao significa reescrever o projeto inteiro, trocar arquitetura consolidada sem necessidade, ou fazer refactors cosmeticos sem beneficio operacional.

## Abordagem recomendada

### Opcao A: risco tecnico primeiro

Corrigir ownership, params, workers, concorrencia, bugs de campos, atom safety e testes frageis antes de entrar nos grandes refactors.

Vantagens:

- reduz risco de refatorar em cima de comportamento quebrado
- estabiliza contratos antes de simplificar codigo
- gera base mais segura para limpeza posterior

Desvantagens:

- o diff inicial pode parecer menos "bonito"
- parte da melhoria de legibilidade fica para depois

### Opcao B: legibilidade primeiro

Entrar primeiro nos warnings de Credo, complexidade e consistencia visual do codigo.

Vantagens:

- melhora a navegacao no codigo cedo
- ajuda a identificar extracoes naturais

Desvantagens:

- maior risco de esconder bug real dentro de refactor
- pior previsibilidade se houver contratos quebrados

### Opcao C: modulo por modulo

Escolher um hotspot e fazer uma limpeza total nele de uma vez.

Vantagens:

- alta coesao local
- cada modulo pode sair fechado

Desvantagens:

- progresso global mais lento
- pode deixar problemas transversais sem tratamento por muito tempo

### Escolha

Usar Opcao A. O trabalho sera executado em fases orientadas a risco, e nao por estetica.

## Escopo confirmado

O trabalho cobre cinco frentes:

1. bugs reais e inconsistencias de contrato
2. seguranca e ownership em contexts e changesets
3. concorrencia e OTP onde hoje ha fire-and-forget ou sincronizacao fragil
4. alinhamento com convencoes Elixir/Phoenix/HEEx
5. reducao de complexidade e limpeza estrutural dos hotspots do Credo

## Problemas-alvo iniciais

Os primeiros problemas confirmados no codigo sao:

- `user_id` sendo aceito pelo changeset de provider e preenchido via params de form
- inconsistencia entre rota com `:provider_id` e callback que espera `%{"id" => ...}`
- worker de sync lendo campo incompatível com o schema
- criacao dinamica de atom em configuracao de endpoints
- uso de `Task.start/1` para efeitos colaterais sem supervisao adequada
- uso recorrente de `Process.sleep/1` em testes onde o ecossistema oferece alternativas melhores
- comentarios HTML comuns em HEEx e alguns trechos menos idiomaticos em templates
- funcoes e modulos grandes demais em `AI`, `stream_token`, `xtream_client`, helpers de player e partes do sync

## Fases de execucao

### Fase 1: correcoes criticas

Objetivo:

- corrigir bugs funcionais e de ownership antes de refatorar

Inclui:

- mover ownership sensivel para contextos
- deixar changesets mais restritivos
- corrigir mismatch de params/rotas
- corrigir campos quebrados em workers e broadcasts
- remover criacao dinamica de atom onde nao for necessaria

Critério de saida:

- os bugs confirmados estao cobertos por testes e corrigidos

### Fase 2: base de testes e confianca

Objetivo:

- tornar os testes dos fluxos alterados previsiveis

Inclui:

- substituir sleeps frageis quando houver alternativa razoavel
- adicionar testes de regressao para os bugs corrigidos
- ajustar testes LiveView e de processos para depender de sinais observaveis

Critério de saida:

- testes dos fluxos alterados falham pelo motivo correto antes das correcoes e passam depois

### Fase 3: convergencia idiomatica

Objetivo:

- alinhar o projeto com as convencoes mais importantes do ecossistema

Inclui:

- HEEx comments corretos
- formularios e inputs em linha com Phoenix 1.8
- simplificacao de trechos pouco idiomaticos
- pequenos ajustes de aliases/imports, guardas e padroes repetidos

Critério de saida:

- os principais desvios de convencao deixam de ser recorrentes

### Fase 4: refactors de complexidade

Objetivo:

- reduzir custo de manutencao dos hotspots sem reescrever o sistema

Inclui:

- quebrar funcoes grandes
- extrair helpers privados com contratos claros
- separar ramificacoes de erro/infra de regras de negocio
- reduzir nesting e complexidade ciclomática nos modulos mais importantes

Prioridade:

- `Streamix.AI.UserAnalytics`
- `StreamixWeb.StreamToken`
- `Streamix.Iptv.XtreamClient`
- `StreamixWeb.PlayerHelpers`
- modulos de sync e streaming que o Credo sinalizar como prioridade

Critério de saida:

- os hotspots mais relevantes do Credo diminuem sem regressao funcional

### Fase 5: fechamento

Objetivo:

- provar que o estado final esta correto

Inclui:

- formatacao
- Credo
- testes
- `mix precommit`
- ultima passada manual nos diffs mais sensiveis

Critério de saida:

- `mix precommit` verde
- sem bugs confirmados ainda em aberto dentro do escopo

## Principios de implementacao

- corrigir comportamento antes de embelezar o codigo
- evitar refactors enormes quando extracoes menores resolvem
- preservar padroes consolidados do projeto quando eles forem coerentes
- preferir interfaces pequenas e explicitas
- manter nomes e contratos previsiveis entre router, LiveView, context e schema
- nao introduzir dependencias novas sem necessidade objetiva

## Politica de refactor

Refactors sao permitidos quando:

- removem risco real
- reduzem complexidade observavel
- melhoram testabilidade
- eliminam repeticao de contrato ou de logica critica

Refactors nao sao prioridade quando:

- sao apenas gosto pessoal
- mexem em muitos arquivos sem ganho funcional
- substituem padroes do projeto que ja estao consistentes

## Estrategia de testes

Cada bug ou ajuste estrutural relevante deve ter uma prova automatizada.

Preferencias:

- testes de context para ownership, validacao e contratos
- testes de LiveView para params, forms e acoes do usuario
- testes de processos usando observacao de mensagens/estado em vez de `sleep`
- testes de regressao pequenos e localizados

## Riscos e mitigacoes

### Risco: churn excessivo

Mitigacao:

- dividir por fases
- validar a cada bloco
- nao misturar refactor amplo com varias mudancas comportamentais sem teste

### Risco: refactor em modulo complexo quebrar comportamento lateral

Mitigacao:

- adicionar teste de regressao antes
- extrair em passos pequenos
- verificar comandos completos no fim de cada etapa relevante

### Risco: cleanup visual consumir o tempo todo

Mitigacao:

- priorizar apenas os desvios com impacto tecnico ou de manutencao

## Arquivos e areas com maior probabilidade de mudanca

- `lib/streamix/iptv/provider.ex`
- `lib/streamix/iptv/providers.ex`
- `lib/streamix/workers/sync_provider_worker.ex`
- `lib/streamix/application.ex`
- `lib/streamix/accounts/ip_tracker.ex`
- `lib/streamix/iptv/gindex/endpoint_manager.ex`
- `lib/streamix_web/live/providers/provider_form_component.ex`
- `lib/streamix_web/live/providers/provider_list_live.ex`
- `lib/streamix_web/components/layouts/*.heex`
- `lib/streamix_web/live/**/*.ex`
- `lib/streamix/ai/user_analytics.ex`
- `lib/streamix_web/stream_token.ex`
- `lib/streamix/iptv/xtream_client.ex`
- `test/**/*`

## Definicao de pronto

O trabalho termina quando:

- os bugs identificados estao corrigidos
- ownership e fluxo de params sensiveis estao endurecidos
- os principais desvios idiomaticos foram removidos
- os hotspots prioritarios de complexidade foram atacados
- a verificacao final passa integralmente com `mix precommit`

