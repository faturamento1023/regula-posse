/* =====================================================================
   REGULA POSSE — gerador de QR Code
   ---------------------------------------------------------------------
   Por que escrever isto em vez de usar biblioteca ou serviço:

   - Serviço externo de QR está fora de questão: mandaríamos o número do
     protocolo do paciente para um terceiro, e o Content-Security-Policy
     da aplicação proíbe requisição para fora do Supabase.
   - Biblioteca via CDN cairia no mesmo problema do supabase-js, com a
     diferença de que aqui o código é pequeno o bastante para caber no
     repositório e ser lido por inteiro.

   Escopo deliberadamente estreito: modo byte, níveis de correção L e M,
   versões 1 a 10 (até 271 bytes em L). É o que uma URL de acompanhamento
   precisa, e cada combinação é verificada em test/qr.test.js decodificando
   a saída com o OpenCV.

   Referência: ISO/IEC 18004.
   ===================================================================== */

/* ---------------- GF(256), com polinômio primitivo 0x11D ---------------- */
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
(function tabelas(){
  let x = 1;
  for(let i = 0; i < 255; i++){
    EXP[i] = x;
    LOG[x] = i;
    x <<= 1;
    if(x & 0x100) x ^= 0x11d;
  }
  for(let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();

const mul = (a, b) => (a === 0 || b === 0) ? 0 : EXP[LOG[a] + LOG[b]];

/** Polinômio gerador de grau `grau`, para Reed-Solomon. */
function gerador(grau){
  let g = [1];
  for(let i = 0; i < grau; i++){
    const novo = new Array(g.length + 1).fill(0);
    for(let j = 0; j < g.length; j++){
      novo[j]     ^= mul(g[j], 1);
      novo[j + 1] ^= mul(g[j], EXP[i]);
    }
    g = novo;
  }
  return g;
}

/** Códigos de correção de erro para um bloco de dados. */
function corrigir(dados, nEC){
  const g = gerador(nEC);
  const resto = new Array(nEC).fill(0);
  for(const byte of dados){
    const fator = byte ^ resto[0];
    resto.shift();
    resto.push(0);
    if(fator !== 0){
      for(let i = 0; i < nEC; i++) resto[i] ^= mul(g[i + 1], fator);
    }
  }
  return resto;
}

/* ---------------- tabelas por versão e nível ----------------
   [ total de códigos de dados, EC por bloco, blocos do grupo 1,
     dados por bloco no grupo 1, blocos do grupo 2, dados por bloco no grupo 2 ]
   ------------------------------------------------------------ */
const BLOCOS = {
  L: [
    [19, 7, 1, 19, 0, 0], [34, 10, 1, 34, 0, 0], [55, 15, 1, 55, 0, 0],
    [80, 20, 1, 80, 0, 0], [108, 26, 1, 108, 0, 0], [136, 18, 2, 68, 0, 0],
    [156, 20, 2, 78, 0, 0], [194, 24, 2, 97, 0, 0], [232, 30, 2, 116, 0, 0],
    [274, 18, 2, 68, 2, 69],
  ],
  M: [
    [16, 10, 1, 16, 0, 0], [28, 16, 1, 28, 0, 0], [44, 26, 1, 44, 0, 0],
    [64, 18, 2, 32, 0, 0], [86, 24, 2, 43, 0, 0], [108, 16, 4, 27, 0, 0],
    [124, 18, 4, 31, 0, 0], [154, 22, 2, 38, 2, 39], [182, 22, 3, 36, 2, 37],
    [216, 26, 4, 43, 1, 44],
  ],
};

/* Centros dos padrões de alinhamento, por versão (vazio na versão 1). */
const ALINHAMENTO = [
  [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
  [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
];

/* Informação de versão (BCH 18,6), necessária a partir da versão 7. */
const INFO_VERSAO = { 7: 0x07c94, 8: 0x085bc, 9: 0x09a99, 10: 0x0a4d3 };

const BITS_NIVEL = { L: 0b01, M: 0b00 };

/* ---------------- codificação dos dados ---------------- */

function bytesDe(texto){
  // Sem TextEncoder: este módulo roda no node e no navegador, e UTF-8 à mão
  // aqui são dez linhas. encodeURIComponent já faz o trabalho pesado.
  const out = [];
  for(const ch of unescape(encodeURIComponent(String(texto)))) out.push(ch.charCodeAt(0));
  return out;
}

function escolherVersao(nBytes, nivel){
  const tab = BLOCOS[nivel];
  for(let v = 1; v <= tab.length; v++){
    const capacidade = tab[v - 1][0];
    const bitsContagem = v <= 9 ? 8 : 16;
    const bitsNecessarios = 4 + bitsContagem + nBytes * 8;
    if(bitsNecessarios <= capacidade * 8) return v;
  }
  return null;
}

function montarCodigos(bytes, versao, nivel){
  const [totalDados, nEC, b1, d1, b2, d2] = BLOCOS[nivel][versao - 1];
  const bitsContagem = versao <= 9 ? 8 : 16;

  const bits = [];
  const empurrar = (valor, n) => { for(let i = n - 1; i >= 0; i--) bits.push((valor >> i) & 1); };

  empurrar(0b0100, 4);                 // modo byte
  empurrar(bytes.length, bitsContagem);
  for(const b of bytes) empurrar(b, 8);

  // terminador, no que couber
  for(let i = 0; i < 4 && bits.length < totalDados * 8; i++) bits.push(0);
  while(bits.length % 8 !== 0) bits.push(0);

  const dados = [];
  for(let i = 0; i < bits.length; i += 8){
    let b = 0;
    for(let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
    dados.push(b);
  }
  // preenchimento alternado, conforme a norma
  const PAD = [0xec, 0x11];
  for(let i = 0; dados.length < totalDados; i++) dados.push(PAD[i % 2]);

  // divide em blocos e calcula a correção de cada um
  const blocosDados = [], blocosEC = [];
  let pos = 0;
  for(const [qtd, tam] of [[b1, d1], [b2, d2]]){
    for(let i = 0; i < qtd; i++){
      const bloco = dados.slice(pos, pos + tam);
      pos += tam;
      blocosDados.push(bloco);
      blocosEC.push(corrigir(bloco, nEC));
    }
  }

  // intercala: primeiro os dados, depois a correção
  const saida = [];
  const maiorDados = Math.max(...blocosDados.map(b => b.length));
  for(let i = 0; i < maiorDados; i++){
    for(const b of blocosDados) if(i < b.length) saida.push(b[i]);
  }
  for(let i = 0; i < nEC; i++){
    for(const b of blocosEC) saida.push(b[i]);
  }
  return saida;
}

/* ---------------- desenho da matriz ---------------- */

function matrizBase(versao){
  const n = versao * 4 + 17;
  // null = livre para dados; true/false = módulo de função já definido
  const m = Array.from({ length: n }, () => new Array(n).fill(null));
  const reservado = Array.from({ length: n }, () => new Array(n).fill(false));

  const marcar = (x, y, v) => { m[y][x] = v; reservado[y][x] = true; };

  // três padrões de busca, com separador
  for(const [ox, oy] of [[0, 0], [n - 7, 0], [0, n - 7]]){
    for(let dy = -1; dy <= 7; dy++){
      for(let dx = -1; dx <= 7; dx++){
        const x = ox + dx, y = oy + dy;
        if(x < 0 || y < 0 || x >= n || y >= n) continue;
        const borda = dx === -1 || dy === -1 || dx === 7 || dy === 7;
        const anel  = dx === 0 || dy === 0 || dx === 6 || dy === 6;
        const miolo = dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4;
        marcar(x, y, borda ? false : (anel || miolo));
      }
    }
  }

  // linhas de temporização
  for(let i = 8; i < n - 8; i++){
    marcar(i, 6, i % 2 === 0);
    marcar(6, i, i % 2 === 0);
  }

  // padrões de alinhamento, exceto onde colidem com os de busca
  const centros = ALINHAMENTO[versao - 1];
  for(const cy of centros){
    for(const cx of centros){
      const perto = (cx <= 8 && cy <= 8) || (cx <= 8 && cy >= n - 9) || (cx >= n - 9 && cy <= 8);
      if(perto) continue;
      for(let dy = -2; dy <= 2; dy++){
        for(let dx = -2; dx <= 2; dx++){
          const anel = Math.max(Math.abs(dx), Math.abs(dy));
          marcar(cx + dx, cy + dy, anel !== 1);
        }
      }
    }
  }

  // módulo sempre escuro
  marcar(8, n - 8, true);

  // áreas de formato e de versão ficam reservadas, preenchidas no fim
  for(let i = 0; i < 9; i++){
    if(m[8][i] === null) marcar(i, 8, false);
    if(m[i][8] === null) marcar(8, i, false);
  }
  for(let i = 0; i < 8; i++){
    if(m[8][n - 1 - i] === null) marcar(n - 1 - i, 8, false);
    if(m[n - 1 - i][8] === null) marcar(8, n - 1 - i, false);
  }
  if(versao >= 7){
    for(let i = 0; i < 6; i++){
      for(let j = 0; j < 3; j++){
        marcar(n - 11 + j, i, false);
        marcar(i, n - 11 + j, false);
      }
    }
  }
  return { m, reservado, n };
}

function colocarDados(m, reservado, n, codigos){
  const bits = [];
  for(const b of codigos) for(let i = 7; i >= 0; i--) bits.push((b >> i) & 1);

  let i = 0, subindo = true;
  for(let col = n - 1; col > 0; col -= 2){
    if(col === 6) col--;                         // a coluna 6 é de temporização
    for(let passo = 0; passo < n; passo++){
      const y = subindo ? n - 1 - passo : passo;
      for(const x of [col, col - 1]){
        if(reservado[y][x]) continue;
        m[y][x] = i < bits.length ? bits[i] === 1 : false;
        i++;
      }
    }
    subindo = !subindo;
  }
}

const MASCARAS = [
  (x, y) => (x + y) % 2 === 0,
  (x, y) => y % 2 === 0,
  (x, y) => x % 3 === 0,
  (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(y / 2) + Math.floor(x / 3)) % 2 === 0,
  (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
  (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
  (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
];

/** Penalidades das quatro regras da norma, para escolher a máscara. */
function penalidade(m, n){
  let p = 0;

  // regra 1: sequências de 5 ou mais módulos iguais
  for(let i = 0; i < n; i++){
    for(const pegar of [(k) => m[i][k], (k) => m[k][i]]){
      let run = 1;
      for(let k = 1; k < n; k++){
        if(pegar(k) === pegar(k - 1)) run++;
        else { if(run >= 5) p += 3 + (run - 5); run = 1; }
      }
      if(run >= 5) p += 3 + (run - 5);
    }
  }

  // regra 2: blocos 2x2 de mesma cor
  for(let y = 0; y < n - 1; y++){
    for(let x = 0; x < n - 1; x++){
      const v = m[y][x];
      if(v === m[y][x + 1] && v === m[y + 1][x] && v === m[y + 1][x + 1]) p += 3;
    }
  }

  // regra 3: padrão 1011101 com quatro claros de um dos lados
  const ALVO = [true, false, true, true, true, false, true];
  const claros = [false, false, false, false];
  const casa = (arr, ini, seq) => seq.every((v, k) => arr[ini + k] === v);
  for(let i = 0; i < n; i++){
    const linha = m[i], coluna = m.map(r => r[i]);
    for(const arr of [linha, coluna]){
      for(let k = 0; k + 11 <= n; k++){
        if(casa(arr, k, [...ALVO, ...claros]) || casa(arr, k, [...claros, ...ALVO])) p += 40;
      }
    }
  }

  // regra 4: desvio da proporção de 50% de módulos escuros
  let escuros = 0;
  for(let y = 0; y < n; y++) for(let x = 0; x < n; x++) if(m[y][x]) escuros++;
  const pct = (escuros * 100) / (n * n);
  p += 10 * Math.floor(Math.abs(pct - 50) / 5);

  return p;
}

/** Informação de formato: BCH(15,5) com máscara 0x5412. */
function bitsFormato(nivel, mascara){
  const dados = (BITS_NIVEL[nivel] << 3) | mascara;
  let v = dados << 10;
  for(let i = 4; i >= 0; i--){
    if(v & (1 << (i + 10))) v ^= 0b10100110111 << i;
  }
  return ((dados << 10) | v) ^ 0b101010000010010;
}

function aplicarFormato(m, n, nivel, mascara, versao){
  const f = bitsFormato(nivel, mascara);
  const bit = i => ((f >> i) & 1) === 1;

  /* Atenção à ordem dos índices: m[y][x]. A primeira cópia sobe pela coluna
     8 e dobra na linha 8; a segunda faz o caminho inverso. Trocar x por y
     aqui gera um QR de aparência perfeita que leitor nenhum decodifica. */

  // primeira cópia, ao redor do padrão de busca superior esquerdo
  for(let i = 0; i <= 5; i++) m[i][8] = bit(i);          // x=8, y=i
  m[7][8] = bit(6);                                      // x=8, y=7
  m[8][8] = bit(7);                                      // x=8, y=8
  m[8][7] = bit(8);                                      // x=7, y=8
  for(let i = 9; i <= 14; i++) m[8][14 - i] = bit(i);    // x=14-i, y=8

  // segunda cópia: linha 8 à direita, coluna 8 embaixo
  for(let i = 0; i <= 7; i++) m[8][n - 1 - i] = bit(i);      // x=n-1-i, y=8
  for(let i = 8; i <= 14; i++) m[n - 15 + i][8] = bit(i);    // x=8, y=n-15+i

  // o módulo sempre escuro não faz parte do formato e é reafirmado aqui,
  // porque a reserva feita em matrizBase cobre as duas orientações
  m[n - 8][8] = true;

  if(versao >= 7){
    const iv = INFO_VERSAO[versao];
    for(let i = 0; i < 18; i++){
      const b = ((iv >> i) & 1) === 1;
      m[Math.floor(i / 3)][n - 11 + (i % 3)] = b;
      m[n - 11 + (i % 3)][Math.floor(i / 3)] = b;
    }
  }
}

/**
 * Gera a matriz do QR Code.
 * @param {string} texto    conteúdo (modo byte, UTF-8)
 * @param {'L'|'M'} nivel   nível de correção de erro
 * @returns {{tamanho:number, modulos:boolean[][], versao:number, nivel:string}}
 */
export function gerarQR(texto, nivel = 'M'){
  if(!BLOCOS[nivel]) throw new Error(`Nível de correção não suportado: ${nivel} (use L ou M)`);
  const bytes = bytesDe(texto);
  const versao = escolherVersao(bytes.length, nivel);
  if(!versao) throw new Error(`Texto longo demais para as versões 1 a 10 no nível ${nivel}: ${bytes.length} bytes`);

  const codigos = montarCodigos(bytes, versao, nivel);

  let melhor = null;
  for(let mascara = 0; mascara < 8; mascara++){
    const { m, reservado, n } = matrizBase(versao);
    colocarDados(m, reservado, n, codigos);
    for(let y = 0; y < n; y++){
      for(let x = 0; x < n; x++){
        if(!reservado[y][x] && MASCARAS[mascara](x, y)) m[y][x] = !m[y][x];
      }
    }
    aplicarFormato(m, n, nivel, mascara, versao);
    const p = penalidade(m, n);
    if(!melhor || p < melhor.p) melhor = { p, m, n };
  }
  return { tamanho: melhor.n, modulos: melhor.m.map(r => r.map(Boolean)), versao, nivel };
}

/**
 * QR Code como SVG, para a guia impressa.
 * @param {string} texto
 * @param {{lado?:number, margem?:number, nivel?:'L'|'M', titulo?:string}} opcoes
 *        lado em px do SVG; margem em módulos (a norma pede 4).
 */
export function qrSVG(texto, opcoes = {}){
  const { lado = 120, margem = 4, nivel = 'M', titulo = 'QR Code' } = opcoes;
  const { tamanho, modulos } = gerarQR(texto, nivel);
  const total = tamanho + margem * 2;

  // Um único <path> em vez de um retângulo por módulo: o SVG fica bem menor
  // e imprime sem costuras claras entre os quadrados.
  let d = '';
  for(let y = 0; y < tamanho; y++){
    for(let x = 0; x < tamanho; x++){
      if(modulos[y][x]) d += `M${x + margem} ${y + margem}h1v1h-1z`;
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${lado}" height="${lado}" `
    + `viewBox="0 0 ${total} ${total}" shape-rendering="crispEdges" role="img" `
    + `aria-label="${String(titulo).replace(/[&<>"]/g, '')}">`
    + `<rect width="${total}" height="${total}" fill="#fff"/>`
    + `<path d="${d}" fill="#000"/></svg>`;
}
