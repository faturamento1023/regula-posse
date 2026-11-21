#!/usr/bin/env bash
# Backup do Regula Posse: dados da aplicação + contas de acesso.
#
# Os dois arquivos são necessários. O dump do schema public NÃO traz o
# schema auth, que o Supabase gerencia, e perfis.id referencia
# auth.users(id): restaurando só o dump num projeto novo, todo perfil falha
# na chave estrangeira e ninguém consegue entrar. Ver OPERACAO.md.
#
# Uso:  URL_DO_BANCO='postgresql://...' ./ferramentas/backup.sh [pasta]
set -euo pipefail

: "${URL_DO_BANCO:?Defina URL_DO_BANCO com a connection string do Supabase (Project Settings > Database > URI)}"

DESTINO="${1:-backups}"
DATA="$(date +%Y%m%d-%H%M)"
mkdir -p "$DESTINO"

DUMP="$DESTINO/regula-posse-$DATA.dump"
CONTAS="$DESTINO/auth-users-$DATA.csv"

echo "1/2  Dados da aplicação -> $DUMP"
pg_dump "$URL_DO_BANCO" -n public --no-owner --no-privileges -Fc -f "$DUMP"

echo "2/2  Contas de acesso   -> $CONTAS"
psql "$URL_DO_BANCO" -Atc \
  "copy (select id, email, raw_user_meta_data, created_at from auth.users)
   to stdout with csv header" > "$CONTAS"

echo
echo "Pronto:"
ls -lh "$DUMP" "$CONTAS" | awk '{print "  " $9 "  " $5}'
echo
echo "Guarde os DOIS arquivos, e em lugar diferente do Supabase."
echo "Teste a restauração a cada seis meses — o procedimento está em OPERACAO.md."
