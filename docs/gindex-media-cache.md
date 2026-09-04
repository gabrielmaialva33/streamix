# Cache de faixas do GIndex

Conteúdo GIndex é servido por `gindex.mahina.fun/stream`, que resolve o token
contra `/api/stream/resolve` e faz proxy dos bytes do Google Drive sem passar
pelo BEAM. Desde 4 de setembro de 2026 essa location cacheia faixas de bytes.

> O bloco nginx do GIndex vive **apenas na VPS**, em
> `/etc/nginx/sites-available/mahina-proxies`. O template versionado
> [`nginx-stream-proxy.conf`](nginx-stream-proxy.conf) cobre só os quatro
> proxies de stream e imagem. Reconstruir a config a partir dele perderia o
> proxy do GIndex inteiro, não só este cache.

## Por que

O player (libmedia dentro do AVPlayer) pede sempre a mesma coisa ao abrir um
filme, medido em produção:

| Faixa | Tamanho | O que é |
|---|---|---|
| `bytes=0-8388607` | 8 MiB | cabeçalho do container |
| `bytes=<fim-83k>-<fim>` | 83 KB | índice, no fim do arquivo |
| `bytes=5839-8394447` | 8 MiB | início da mídia, **sobrepõe quase todo o primeiro** |

São 16 MB para mostrar o primeiro frame, metade redundante. O 8 MiB é constante
interna do bundle vendorizado do libmedia, não é opção que passamos.

O upstream é instável de um jeito que a média esconde. Repetindo essa sequência
seis vezes contra a versão sem cache:

```
4,5s   85,9s   TIMEOUT(240s)   243,2s   6,6s   4,2s   6,6s
```

Com as faixas cacheadas, as mesmas leituras ficam entre 0,05 e 0,17 s. O ganho
principal não é a média, é tirar o usuário dessa loteria.

## Como

Na location `= /stream`:

```nginx
proxy_buffering         on;          # slice exige buffering
proxy_buffers           32 256k;
slice                   8m;
proxy_cache             gindex_media_cache;
proxy_cache_key         "gindex:$gindex_ct:$gindex_cid:$slice_range";
proxy_cache_valid       200 206 14d;
proxy_cache_lock        on;
proxy_ignore_headers    Cache-Control Expires Vary Set-Cookie;
proxy_set_header Range  $slice_range;
proxy_no_cache          $gindex_cid_empty;
proxy_cache_bypass      $gindex_cid_empty;
```

Com a zona declarada no topo do arquivo:

```nginx
proxy_cache_path /var/cache/nginx/gindex_media
    levels=1:2 keys_zone=gindex_media_cache:64m max_size=60g
    inactive=14d use_temp_path=off;
```

Três decisões que não são óbvias:

**A chave vem da identidade do conteúdo, nunca do token.** O `rewrite_by_lua_block`
lê `content_type` e `content_id` do JSON de resolve para dentro de
`$gindex_ct` e `$gindex_cid`. Token e URL assinada do Drive rotacionam a cada
request; chavear por eles daria 0% de acerto. Quando o id vem vazio, o objeto
não é cacheado, para não envenenar a chave.

**Fatia de 8 MiB, não menor.** Ela é dimensionada para o read que o player
realmente faz. Medido com a sequência real, cache frio e quente:

| Fatia | Frio | Quente |
|---|---|---|
| sem cache | 4,07 s | 4,07 s |
| 8 MiB | 6,07 s | **0,13 s** |
| 2 MiB | 7,58 s | 1,79 s |

Fatias menores transformam uma ida ao upstream em várias serializadas contra
uma origem de ~1 s de latência, e ficam piores nos dois cenários.

**`Cache-Control` do upstream é ignorado de propósito.** O Drive responde
`Cache-Control: private, max-age=0, must-revalidate` mais um `Vary`, o que
proibiria o cache. Ignorar é seguro aqui porque os bytes só são alcançáveis
depois da checagem de token no Lua, e a chave é a nossa identidade de conteúdo,
não a do chamador.

## Rollback

A versão sem cache continua montada como `= /stream-direct`. Reverter é trocar
os nomes das duas locations e recarregar:

```bash
F=/etc/nginx/sites-available/mahina-proxies
sed -i 's|^    location = /stream {|    location = /stream-cached {|' "$F"
sed -i 's|^    location = /stream-direct {|    location = /stream {|' "$F"
nginx -t && systemctl reload nginx
```

Backups anteriores à troca ficam em `/root/np.bak-preswitch-*`.

## O que sobrou

Com os bytes vindo em menos de 1 s, o tempo até o primeiro frame caiu de 14,2 s
para algo entre 8,2 e 9,1 s. O restante é inicialização de decoder no cliente,
não rede. Esse número é um piso pessimista: foi medido em Chromium headless, que
reporta `VideoDecoder not support` e cai em decodificação por software.
