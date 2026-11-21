#!/usr/bin/env bash
# Baixa o supabase-js para dentro do repositório e imprime a tag <script>
# com o hash de integridade (SRI).
#
# Por que: hoje o arquivo vem do jsDelivr. A versão está fixada, o que
# evita surpresa de atualização, mas um CDN comprometido entregaria código
# com acesso ao token de sessão e aos dados de paciente. Com o arquivo
# versionado aqui, o CSP pode proibir script de qualquer outra origem.
#
# Uso:  ./ferramentas/vendorizar-supabase.sh [versão]
set -euo pipefail

VERSAO="${1:-2.49.4}"
DESTINO="assets/vendor/supabase.min.js"
URL="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@${VERSAO}/dist/umd/supabase.min.js"

cd "$(dirname "$0")/.."
mkdir -p "$(dirname "$DESTINO")"

echo "Baixando $URL"
curl -fsSL "$URL" -o "$DESTINO"

SRI="sha384-$(openssl dgst -sha384 -binary "$DESTINO" | openssl base64 -A)"

echo
echo "Arquivo salvo em $DESTINO ($(wc -c < "$DESTINO") bytes)"
echo
echo "1) Em index.html, troque a tag do jsDelivr por:"
echo
echo "   <script src=\"$DESTINO\" integrity=\"$SRI\" crossorigin=\"anonymous\"></script>"
echo
echo "2) No <meta> do Content-Security-Policy, troque"
echo "     script-src 'self' https://cdn.jsdelivr.net"
echo "   por"
echo "     script-src 'self'"
echo
echo "3) Faça commit do arquivo baixado junto com a mudança no index.html."
