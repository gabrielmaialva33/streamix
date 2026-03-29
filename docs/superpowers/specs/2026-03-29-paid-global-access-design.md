# Paid Global Access Design

Date: 2026-03-29
Status: Approved in conversation

## Context

`Streamix` hoje permite cadastro público e acesso autenticado ao catálogo global da plataforma. O modelo comercial desejado muda esse comportamento:

- o cadastro público continua aberto
- usuários sem assinatura continuam podendo navegar no catálogo global
- usuários sem assinatura nao podem reproduzir conteúdo `system/global`
- o bloqueio premium nao se aplica ao conteúdo vindo de providers do próprio usuário
- admins sempre mantêm acesso total

O primeiro corte nao inclui billing real. A concessão de assinatura será operacional/manual, mas a modelagem já deve preparar planos, histórico e futuras integrações de pagamento.

## Goals

- manter o cadastro público
- preservar a descoberta do catálogo global
- bloquear playback premium de conteúdo `system/global` para usuários sem assinatura ativa
- permitir playback normal de conteúdo de providers próprios do usuário
- introduzir base de dados correta para planos, assinaturas e permissões
- preparar o sistema para upgrades futuros como checkout, convites e degustação de 60 segundos

## Non-Goals

- integrar checkout real neste primeiro corte
- implementar trials ou degustação de 60 segundos agora
- fechar o cadastro público
- bloquear a navegação do catálogo global para usuários sem assinatura

## Product Rules

### Registration

- `/register` continua disponível para visitantes
- novos usuários entram com papel padrão de cliente comum
- nenhum usuário novo recebe acesso premium automaticamente

### Global Catalog Access

- usuários autenticados podem navegar no catálogo global
- usuários autenticados podem abrir páginas de detalhe do catálogo global
- usuários autenticados podem abrir a tela do player para conteúdo global

### Premium Playback Rule

Playback de conteúdo `system/global` só é permitido quando:

- `user.role == admin`, ou
- o usuário possui assinatura ativa e vigente

Playback de conteúdo de provider próprio do usuário continua permitido sem assinatura premium.

### Premium Boundary

A regra premium vale para qualquer conteúdo associado a provider `system/global`, independentemente da fonte:

- Xtream global
- GIndex global
- qualquer outro provider interno da plataforma marcado como `is_system/global`

Essa regra nao se aplica automaticamente a providers criados por usuários, mesmo se algum dia eles puderem ser públicos.

## UX

### Catalog Experience

- catálogo global continua visível
- cards e detalhes de conteúdo global devem exibir sinalização premium
- a UI deve deixar claro que navegação é livre e playback exige assinatura

### Player Experience

Quando um usuário sem acesso tenta reproduzir conteúdo `system/global`:

- o player nao deve iniciar playback
- a app deve redirecionar para `/plans`
- a rota pode carregar `flash` explicando que o conteúdo exige assinatura ativa

### Plans Page

Criar página pública/logada em `/plans`.

Comportamento esperado:

- visitante sem login vê os planos e proposta comercial
- usuário logado sem assinatura vê CTA de assinatura
- usuário com assinatura ativa vê status da assinatura atual
- admin vê a página sem bloqueio

No primeiro corte, essa página ainda nao executa checkout real.

## Data Model

### Users

Adicionar `role` em `users`.

Valores iniciais:

- `admin`
- `customer`

`customer` é o padrão para cadastro público.

Observação:

- nao usar `subscriber` como papel neste momento
- ser assinante é estado comercial, nao identidade estrutural

### Plans

Criar `plans` como catálogo de planos comercializáveis.

Campos mínimos:

- `name`
- `slug`
- `description`
- `price_cents`
- `currency`
- `billing_interval`
- `active`
- `grants_global_access`

### Subscriptions

Criar `subscriptions` ligando usuário a plano.

Campos mínimos:

- `user_id`
- `plan_id`
- `status`
- `starts_at`
- `expires_at`
- `canceled_at`
- `source`
- `external_reference`

Estados iniciais:

- `pending`
- `active`
- `expired`
- `canceled`

Regra de acesso do primeiro corte:

- existe acesso premium quando há assinatura `active` e vigente pela data atual

### Permissions

Criar `permissions` como catálogo de capacidades nomeadas.

Exemplos:

- `play_global_content`
- `manage_users`
- `manage_subscriptions`
- `manage_providers`

### Role Permissions

Criar `role_permissions` para mapear permissões por papel.

Uso inicial:

- `admin` recebe permissões administrativas por seed
- `customer` recebe só permissões básicas

### User Permissions

Criar `user_permissions` para exceções operacionais por usuário.

Uso inicial:

- override fino sem promover usuário para `admin`
- preparar suporte, operadores e exceções comerciais futuras

## Authorization Model

### Source of Truth

Usar modelo híbrido:

- `users.role` controla acesso alto nível
- `subscriptions` controlam o direito comercial ao conteúdo premium
- permissões refinam exceções e capacidades administrativas

### Recommended Domain API

Centralizar regra de negócio em módulos de domínio, nao em LiveViews/controllers.

Funções candidatas:

- `Accounts.admin?/1`
- `Billing.active_subscription_for_user/1`
- `Billing.subscribed?/1`
- `Access.global_content?/1`
- `Access.can_play_global_content?/1`
- `Access.can_play?/2`

## Phoenix Integration

### Router

Manter:

- `/register` como rota guest
- `/login` como rota guest

Adicionar:

- `/plans` em escopo `:browser`, acessível com ou sem autenticação

Motivo:

- a página precisa servir como destino de upsell tanto da home quanto do player bloqueado
- quando existir `current_scope`, a página pode mostrar o estado da assinatura do usuário

### Web Entry Points

Aplicar o gate em todos os pontos que iniciam playback:

- `PlayerLive`
- endpoints de stream/redirect na camada web
- helpers que resolvem URL final de reprodução
- qualquer API externa que exponha playback de conteúdo premium

### Failure Mode

Em caso de dúvida ou inconsistência:

- falhar fechado para conteúdo premium
- nunca liberar stream global por erro de validação ou ausência de preload

## Operational Model

### First Release

- cadastro público continua aberto
- admin concede assinatura manualmente
- planos existem no banco
- assinatura ativa é criada/ajustada manualmente por operação/admin

### Seeds

Adicionar seeds para:

- usuário admin
- planos base
- permissões base
- associações de permissões do papel admin

Nao seedar assinatura premium automática para usuários comuns.

## Testing Strategy

### Domain Tests

- usuário novo nasce `customer`
- `admin` pode reproduzir conteúdo global
- `customer` sem assinatura nao pode reproduzir conteúdo global
- `customer` com assinatura ativa pode reproduzir conteúdo global
- assinatura expirada ou cancelada nao concede acesso
- conteúdo de provider próprio continua tocando sem assinatura

### LiveView Tests

- catálogo global continua renderizando para usuário autenticado sem assinatura
- tentativa de playback global redireciona para `/plans`
- playback próprio do usuário continua permitido
- usuário com assinatura ativa acessa player premium normalmente

### API/Controller Tests

- endpoints de stream premium negam acesso sem assinatura
- endpoints de stream de providers próprios continuam funcionais
- respostas de erro e redirecionamento permanecem consistentes com a UI

## Rollout Plan

### Phase 1

- introduzir papéis, planos, assinaturas e permissões
- criar `/plans`
- aplicar gate de playback premium

### Phase 2

- adicionar gestão administrativa de assinatura
- melhorar sinalização premium na UI

### Phase 3

- integrar billing real
- opcionalmente adicionar degustação de 60 segundos
- opcionalmente adicionar convites e fluxos comerciais mais refinados

## Risks

- espalhar regra premium em múltiplos LiveViews/controllers gera inconsistência
- depender só de UI para bloqueio permite bypass por API/player externo
- misturar papel de usuário com estado comercial da assinatura reduz clareza do modelo

## Recommendation

Implementar o primeiro corte com:

- `users.role` para acesso alto nível
- `plans` + `subscriptions` como domínio comercial
- permissões como base para evolução administrativa
- gate centralizado no domínio e aplicado no player e nos endpoints de stream

Esse desenho preserva o cadastro aberto, introduz monetização do catálogo global e evita retrabalho quando o billing real entrar.
