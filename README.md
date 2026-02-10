# 📹 Frigate NVR - Scripts de Gerenciamento de Mídia

Sistema automatizado para gerenciamento de armazenamento do [Frigate NVR](https://frigate.video/), movendo gravações do SSD (rápido) para HD externo (longo prazo) e gerenciando retenção.

## 📁 Estrutura de Arquivos

```
scripts/
├── .env                    # Configuração centralizada (EDITE ESTE)
├── .env.local              # Configurações locais (opcional, gitignored)
├── common.sh               # Funções compartilhadas
├── README.md               # Esta documentação
│
├── frigate-mover.sh        # 🆕 Script unificado de movimentação
├── frigate-archive.sh      # → Wrapper para frigate-mover.sh --mode=incremental
├── frigate-archiver.sh     # → Wrapper para frigate-mover.sh --mode=file
├── mover_frigate_para_hd.sh # → Wrapper para frigate-mover.sh --mode=full
│
├── frigate-prune-hd.sh     # Limpa HD quando espaço baixo
├── frigate-vacuum.sh       # Limpa HD quando uso alto
├── frigate-retention.sh    # Remove clips antigos
│
├── frigate-status.sh       # 🆕 Health check e monitoramento
├── frigate-check.sh        # 🆕 Validação de dependências
├── frigate-logrotate.sh    # 🆕 Rotação manual de logs
├── logrotate.conf          # 🆕 Config para logrotate do sistema
├── hd-watchdog-min.sh      # Monitora SSD e aciona mover
└── reset-usb.sh            # Reseta HD USB travado
```

## 🚀 Script Unificado: frigate-mover.sh

O `frigate-mover.sh` consolida toda a funcionalidade de movimentação em um único script com diferentes modos:

### Modos de Operação

| Modo | Descrição | Uso Típico |
|------|-----------|------------|
| `--mode=incremental` | Move por diretório de data (> N dias) | Cron a cada hora |
| `--mode=file` | Move por arquivo individual (> 24h) | Quando precisa granularidade |
| `--mode=full` | Move TUDO com limite de banda | Manutenção programada |
| `--mode=emergency` | Move TUDO sem limite de banda | Emergência de espaço |

### Opções

```bash
./frigate-mover.sh --mode=incremental     # Modo padrão
./frigate-mover.sh --mode=full --dry-run  # Simula sem executar
./frigate-mover.sh --mode=incremental -v  # Verbose
./frigate-mover.sh --status               # Mostra estatísticas
./frigate-mover.sh --help                 # Ajuda completa
```

### Exemplo de --status

```
=== Frigate Storage Status ===

📁 SSD (/mnt/frigate-ssd)
   Uso: 45% | Total: 256G | Livre: 140G
   Dias de gravação: 3

💾 HD Externo (/mnt/hdexterno)
   Uso: 72% | Total: 2.0T | Livre: 560G
   Dias de gravação: 45
```

## 🔧 Configuração

### 1. Copie o arquivo de configuração

```bash
# Edite o .env principal OU crie um .env.local para customizações
cp .env .env.local
nano .env.local
```

### 2. Principais variáveis a configurar

```bash
# Caminhos de armazenamento
SSD_ROOT="/mnt/frigate-ssd"
HD_MOUNT="/mnt/hdexterno"

# Políticas de retenção
KEEP_SSD_DAYS=2         # Dias para manter no SSD
CLIPS_KEEP_DAYS=2       # Dias para manter clips

# Limites de disco
MIN_FREE_PCT=15         # % mínimo livre no HD
HD_USAGE_THRESHOLD=90   # % máximo de uso do HD
SSD_EMERGENCY_THRESHOLD=85  # % que dispara emergência

# Performance
BWLIMIT=20000           # Limite de banda KB/s (20MB/s)
```

### 3. Torne os scripts executáveis

```bash
chmod +x *.sh
```

## 📜 Descrição dos Scripts

### Scripts de Arquivamento (SSD → HD)

| Script | Descrição | Quando Usar |
|--------|-----------|-------------|
| `frigate-archive.sh` | Move diretórios de data inteiros do SSD para HD | Recomendado para uso diário |
| `frigate-archiver.sh` | Move arquivos individuais mais antigos que 24h | Quando precisa de granularidade |
| `mover_frigate_para_hd.sh` | Move TUDO do SSD para HD de uma vez | Emergências ou manutenção |

### Scripts de Limpeza

| Script | Descrição | Gatilho |
|--------|-----------|---------|
| `frigate-prune-hd.sh` | Remove dias antigos até ter espaço livre | Espaço livre < 15% |
| `frigate-vacuum.sh` | Remove dias antigos quando muito cheio | Uso > 90% |
| `frigate-retention.sh` | Remove clips antigos | Clips > 2 dias |

### Scripts Utilitários

| Script | Descrição |
|--------|-----------|
| `hd-watchdog-min.sh` | Monitora SSD e aciona movimentação se > 85% |
| `reset-usb.sh` | Reseta dispositivo USB travado |

## ⏰ Configuração do Cron

Adicione ao crontab (`crontab -e`):

```cron
# Arquiva gravações antigas do SSD para HD (a cada hora)
20 3 * * * /usr/local/sbin/frigate-mover.sh >> /var/log/frigate/frigate-mover.log 2>&1

# Limpa HD quando espaço livre < 15% (diário às 3h)
10 * * * * /usr/local/sbin/frigate-prune-hd.sh

# Remove clips antigos (diário às 4h)
20 3 * * * /usr/local/sbin/frigate-retention.sh

# Watchdog do SSD - verifica a cada minuto
* * * * * /usr/local/sbin/hd-watchdog-min.sh

# Vacuum de emergência (a cada 6 horas)
*/15 * * * * /usr/local/sbin/frigate-vacuum.sh >> /var/log/frigate/frigate-vacuum.log 2>&1
```

## 📊 Logs

Os scripts registram suas operações nos seguintes arquivos:

| Script | Arquivo de Log |
|--------|----------------|
| `frigate-prune-hd.sh` | `/var/log/frigate-prune-hd.log` |
| `frigate-retention.sh` | `/var/log/frigate-retention.log` |
| `mover_frigate_para_hd.sh` | `/var/log/ssd_to_hd.log` |

Para monitorar em tempo real:

```bash
tail -f /var/log/frigate-*.log
```

## 🔒 Mecanismo de Lock

Os scripts usam locks para evitar execuções simultâneas:

- `/var/lock/frigate-storage.lock` - Operações de arquivamento
- `/var/lock/frigate-media.lock` - Operações de mídia (prune, retention)
- `/tmp/mover_frigate.lock` - Script mover

Se um script encontrar o lock ocupado, sai silenciosamente (comportamento esperado).

## 🐛 Troubleshooting

### HD externo não está montando

```bash
# Verifique se está conectado
lsblk

# Monte manualmente
sudo mount /dev/sdX1 /mnt/hdexterno

# Adicione ao fstab para mount automático
echo "UUID=xxxx /mnt/hdexterno ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
```

### HD travou/parou de responder

```bash
# Use o script de reset
./reset-usb.sh

# Se não funcionar, verifique os logs do kernel
dmesg | tail -50
```

### Scripts não estão rodando no cron

```bash
# Verifique o PATH
which rsync docker

# Adicione o PATH no início do crontab
PATH=/usr/local/bin:/usr/bin:/bin

# Verifique logs do cron
grep CRON /var/log/syslog
```

### Descobrir ID do dispositivo USB

```bash
lsusb
# Procure por algo como: Bus 002 Device 003: ID 174c:1153 ASMedia Technology Inc.
# O ID é "174c:1153"
```

## 📝 Notas de Desenvolvimento

### Convenções

- Todos os scripts usam `source common.sh` para configuração
- Logs seguem formato ISO 8601: `[2024-01-15T10:30:00-03:00] [tag] mensagem`
- Paths são sempre variáveis definidas no `.env`
- Locks são liberados automaticamente ao sair (trap EXIT ou flock)

### Testando em modo dry-run

```bash
DRY_RUN=1 ./frigate-archive.sh
```

### Adicionando novos scripts

1. Comece com `source "$(dirname "$0")/common.sh"`
2. Use as funções utilitárias do common.sh
3. Defina uma LOG_TAG para identificação
4. Use locks quando modificar arquivos

## 📄 Licença

Uso interno - Sistema Marquise
