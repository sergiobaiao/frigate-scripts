# Changelog

Este arquivo consolida todas as alteracoes aplicadas nesta sessao de trabalho.
Periodo reconstruido: **2026-02-15 a 2026-02-25**.
Formato baseado em **Keep a Changelog**, adaptado para portugues.

Regra adotada:
- Tudo antes do versionamento formal foi classificado como `0.x`.
- O marco `1.0` representa o inicio oficial do versionamento nos arquivos.
- Toda alteracao futura deve atualizar este arquivo.

## [Nao lancado]
### Alterado
- Nenhuma alteracao pendente.

## [0.1] - 2026-02-15
### Adicionado
- Consolidacao inicial dos scripts operacionais para SSD/HD no fluxo Frigate.

### Contexto
- Base funcional inicial antes do endurecimento de logs, erros e instalacao.

## [0.2] - 2026-02-15
### Alterado
- `README.md`: removidas referencias aos wrappers legados `frigate-archive.sh` e `frigate-archiver.sh`.
- `frigate-mover.sh`: documentacao alinhada ao uso do script unificado.

## [0.3] - 2026-02-15
### Alterado
- `common.sh`: criado padrao de execucao com `set -Eeuo pipefail`.
- `common.sh`: adicionadas funcoes de observabilidade e erro:
  - `setup_logging`
  - `log_warn`
  - `log_error`
  - `notify_event`
  - `notify_error`
  - `setup_error_trap`
  - `on_error`
  - `bytes_human`
  - `collect_path_stats`
- Scripts principais passaram a usar logging estruturado e trap de erro.

### Impacto
- Maior rastreabilidade operacional.
- Notificacao em falhas com contexto de linha/comando.

## [0.4] - 2026-02-16
### Corrigido
- Erros `exit=141` (SIGPIPE com `pipefail`) em:
  - `frigate-mover.sh`
  - `frigate-retention.sh`
  - `frigate-status.sh`
- Substituicoes de pipes sensiveis (`sort | head`, `sort | tail`) por coleta segura de intervalo de datas.

## [0.5] - 2026-02-16
### Alterado
- `frigate-mover.sh`: modo verbose passou a habilitar progresso detalhado de `rsync`.
- `frigate-mover.sh`: adicao de informacoes de quantidade, bytes e datas nas etapas.

### Corrigido
- `frigate-status.sh`: tratamento de variaveis de data vazias em modo full.
- `frigate-retention.sh`: retornos seguros quando nao ha candidatos de limpeza.

## [0.6] - 2026-02-17
### Adicionado
- `frigate-prune-hd.sh`: limpeza manual por data de corte via CLI:
  - `--before-date YYYY-MM-DD`
  - `--manual-mode date-dir` (pastas por nome `YYYY-MM-DD`)
  - `--manual-mode mtime` (arquivos por data real de modificacao)

### Alterado
- `frigate-prune-hd.sh`: logs manuais com resumo de removidos, bytes liberados e datas afetadas.

### Corrigido
- Incremento aritmetico compativel com `set -e` em contadores de remocao.

## [0.7] - 2026-02-17
### Alterado
- `install.sh`:
  - passou a exigir execucao como `root`;
  - define alvo padrao `/usr/local/sbin`;
  - cria estrutura de logs;
  - gerencia crontab do `root`, mantendo apenas os jobs Frigate definidos.

### Adicionado
- Backup automatico da crontab anterior durante instalacao.

## [0.8] - 2026-02-17
### Alterado
- `.env` e resolucao de paths para refletir o cenario real:
  - mountpoints: `/mnt/frigate-ssd` e `/mnt/hdexterno`
  - dados Frigate em subpasta `/frigate/...`
- `common.sh`: normalizacao com `resolve_media_path` para compatibilidade entre layouts.

## [0.9] - 2026-02-17
### Alterado
- Hardening de lock/log fallback em ambiente sem permissao para `/var/log` e `/var/lock`, usando `.runtime`.
- Expansao de logs operacionais em scripts de status, prune, mover, retention e vacuum.

## [1.0] - 2026-02-17
### Adicionado
- Inicio do versionamento formal por arquivo com cabecalho `# VERSION: X.Y`.
- Criado `version-bump.sh` para incrementar versao (`+0.1`) de arquivos alvo.

### Alterado
- Scripts principais e configuracoes passaram a registrar versao explicita.

## [1.1] - 2026-02-18
### Alterado
- `install.sh` -> `VERSION 1.1`: consolidacao final da instalacao e cron do root.
- `README.md` e `.env`: documentacao/configuracoes sincronizadas com o fluxo atualizado.

## [1.2] - 2026-02-16..2026-02-18
### Alterado
- `frigate-status.sh` -> `VERSION 1.2`: melhorias de robustez e erros.
- `frigate-retention.sh` -> `VERSION 1.2`: correcoes de fluxo e logs.
- `reset-usb.sh` -> `VERSION 1.2`: alinhamento com framework comum de logs/erros.
- `.env` -> `VERSION 1.2`: ajustes de caminhos, logs e parametros.
- `version-bump.sh` -> `VERSION 1.2`: melhorias operacionais.

## [1.3] - 2026-02-18
### Alterado
- `frigate-mover.sh` -> `VERSION 1.3`:
  - modo padrao trocado para `file` (data real do arquivo/mtime);
  - modo por pasta mantido separado em `incremental`;
  - copia sem apagar origem por padrao (`file` e `incremental`);
  - remocao de origem restrita a `full` e `emergency`;
  - verbose com progresso de `rsync`.

## [1.4] - 2026-02-19
### Corrigido
- `frigate-mover.sh` -> `VERSION 1.4`:
  - correção do resumo final em `mode=file` para evitar contaminacao por logs durante captura de contadores.
- `common.sh` -> `VERSION 1.1`:
  - correção em `collect_path_stats` para compatibilidade com `set -e` (evitando falha em comparacoes `[[ -z ... ]]`).

### Validado
- `mode=file`: copia por data do arquivo sem remover origem.
- `mode=full`: copia com remocao da origem.

## [1.5] - 2026-02-19
### Alterado
- `README.md` -> `VERSION 1.2`: adicionada secao oficial "Politica do Changelog" com obrigatoriedade de atualizacao em toda mudanca.
- `changelog.md`: padronizacao no estilo Keep a Changelog (portugues) e criacao da secao `Nao lancado`.

## [1.6] - 2026-02-19
### Alterado
- `frigate-reset.sh` -> `VERSION 1.1`:
  - executa migracao full (`frigate-mover.sh --mode=full`) antes da exclusao de dados;
  - em caso de falha na migracao, aborta o reset para evitar perda de dados e tenta religar o container;
  - limpeza de midia passou a apagar apenas o SSD (preservando os dados no HD).

## [1.7] - 2026-02-19
### Alterado
- Sincronizadas as versoes de todos os arquivos com marcador `VERSION` para o mesmo valor: `1.7`.
- `README.md` atualizado para `VERSION 1.7`.
- `.env` e todos os scripts versionados atualizados para `VERSION 1.7`.

## [1.8] - 2026-02-25
### Alterado
- Sincronizacao global de versao para `1.8` em todos os arquivos versionados (incluindo novos scripts e templates de cron).
- `frigate-mover.sh`:
  - `mode=file` passou a usar janela de idade por minutos (`FILE_MIN_AGE_MINUTES`, `FILE_MAX_AGE_MINUTES`) e limite por execução (`FILE_MAX_FILES_PER_RUN`);
  - aplicação de `--bwlimit` também no fluxo `file`/`incremental`;
  - sincronização em lote com `--files-from` e `--ignore-existing`;
  - robustez para corrida de arquivos durante varredura (arquivos ausentes no meio da execução).
- `hd-watchdog-min.sh`:
  - adição de cooldown (`WATCHDOG_COOLDOWN_MINUTES`);
  - adição de modo configurável (`WATCHDOG_MODE`) e override de emergência (`WATCHDOG_USE_EMERGENCY`);
  - persistência de estado em `.runtime/watchdog.last`.
- `frigate-prune-hd.sh`:
  - limpeza automática passou a operar por faixa `YYYY-MM-DD/HH` quando houver estrutura por hora;
  - lock alinhado para usar `LOCK_STORAGE` como prioridade.
- `frigate-vacuum.sh`:
  - remoção por faixa `YYYY-MM-DD/HH` (com fallback para layouts sem subpastas de hora);
  - lock alinhado para usar `LOCK_STORAGE` como prioridade.
- `common.sh`:
  - `collect_path_stats` alterado para coleta de datas sem `head/tail`, reduzindo fragilidade com `pipefail`.
- `README.md`:
  - atualizado para refletir o comportamento atual do `frigate-mover.sh`;
  - adicionada documentação de `frigate-reconcile-gaps.sh`, `ha-localtime-view.sh` e templates de cron atuais.
- `.gitignore`:
  - reforco para ignorar backups offline e artefatos locais (`.bkp/`, `*.bak.*`, `.bak.*`, `.env.bak.`, `*.log`, `*.log.*`).

### Adicionado
- Novos arquivos operacionais detectados e documentados:
  - `frigate-reconcile-gaps.sh`
  - `ha-localtime-view.sh`
  - `ha-localtime-view.cron`
  - `frigate-cron`

---

## Estado atual de versoes (2026-02-25)
- `README.md`: 1.8
- `common.sh`: 1.8
- `frigate-mover.sh`: 1.8
- `frigate-prune-hd.sh`: 1.8
- `frigate-retention.sh`: 1.8
- `frigate-status.sh`: 1.8
- `install.sh`: 1.8
- `version-bump.sh`: 1.8
- `reset-usb.sh`: 1.8
- `frigate-reset.sh`: 1.8
- `frigate-vacuum.sh`: 1.8
- `frigate-check.sh`: 1.8
- `frigate-logrotate.sh`: 1.8
- `hd-watchdog-min.sh`: 1.8
- `list_files_by_date.sh`: 1.8
- `mover_frigate_para_hd.sh`: 1.8
- `.env`: 1.8
- `frigate-cron`: 1.8
- `frigate-reconcile-gaps.sh`: 1.8
- `ha-localtime-view.sh`: 1.8
- `ha-localtime-view.cron`: 1.8
