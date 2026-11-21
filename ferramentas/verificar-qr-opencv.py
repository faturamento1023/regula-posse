#!/usr/bin/env python3
"""Reverifica o gerador de QR contra um leitor independente.

Os hashes de test/qr.test.js garantem que a saída de js/qr.js não mudou,
mas quem garantiu que ela estava CERTA foi este script: ele gera cada
matriz e manda o leitor de QR do OpenCV decodificar. Rode depois de
qualquer mudança em js/qr.js e, se a saída mudar de propósito, atualize
os hashes do teste com os novos valores.

Requer:  pip install opencv-python-headless numpy
Uso:     python3 ferramentas/verificar-qr-opencv.py
"""
import json
import subprocess
import sys

try:
    import cv2
    import numpy as np
except ImportError:
    sys.exit("Faltam dependências: pip install opencv-python-headless numpy")

GERADOR = r"""
import { gerarQR } from './js/qr.js';
const cap = { L:[17,32,53,78,106,134,154,192,230,271], M:[14,26,42,62,84,106,122,152,180,213] };
const casos = [];
for(const nivel of ['L','M'])
  for(let v = 1; v <= 10; v++) casos.push({ nivel, texto: 'A'.repeat(cap[nivel][v-1]) });
for(const texto of [
  'https://saude.posse.go.gov.br/#/acompanhar?p=2026000001',
  '2026000001',
  'Acentuação: ação, José, coração — çÇãõ',
  'https://exemplo.invalid/regula/#/acompanhar?p=2026999999&v=2',
]) casos.push({ nivel:'M', texto });
casos.push({ nivel:'L', texto:'a' });
console.log(JSON.stringify(casos.map(c => {
  const r = gerarQR(c.texto, c.nivel);
  return { ...c, versao:r.versao, tamanho:r.tamanho,
           modulos:r.modulos.map(l => l.map(b => b ? 1 : 0)) };
})));
"""


def main() -> int:
    saida = subprocess.run(
        ["node", "--input-type=module", "-e", GERADOR],
        capture_output=True, text=True, check=True,
    ).stdout
    casos = json.loads(saida)

    leitor = cv2.QRCodeDetector()
    ok = falhas = 0
    for c in casos:
        m = np.array(c["modulos"], dtype=np.uint8)
        n = m.shape[0]
        margem = 4                                  # zona de silêncio exigida pela norma
        img = np.ones((n + 2 * margem,) * 2, dtype=np.uint8)
        img[margem:margem + n, margem:margem + n] = 1 - m     # 1 = claro, 0 = escuro
        ampliada = np.kron(img, np.ones((8, 8), dtype=np.uint8)) * 255

        lido, _, _ = leitor.detectAndDecode(ampliada)
        if lido == c["texto"]:
            ok += 1
        else:
            falhas += 1
            print(f"FALHA  nivel={c['nivel']} versao={c['versao']} "
                  f"tamanho={c['tamanho']} bytes={len(c['texto'].encode())}")
            print(f"       esperado: {c['texto'][:60]!r}")
            print(f"       lido:     {lido[:60]!r}")

    print(f"\n{ok} de {ok + falhas} decodificados corretamente pelo OpenCV")
    return 1 if falhas else 0


if __name__ == "__main__":
    sys.exit(main())
