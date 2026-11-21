/* =====================================================================
   REGULA POSSE — utilitários puros
   ---------------------------------------------------------------------
   Este módulo não toca no DOM nem na rede: tudo aqui é função pura,
   para poder ser testado com `node --test`. Ver test/util.test.js.
   ===================================================================== */

/* ---------------- escape de HTML ---------------- */

/** Escapa um valor para interpolação segura em HTML. */
export const h = v => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));

/**
 * Marca uma string como HTML já confiável, para passar intacta pelo
 * template `html`. Use SOMENTE com HTML gerado pelo próprio sistema
 * (badges, tabelas, trechos montados por outras funções daqui).
 * Nunca com texto que veio do banco ou de um formulário.
 */
export const raw = s => ({ __raw: String(s ?? '') });

/**
 * Template literal que escapa por padrão.
 *
 *   html`<b>${paciente.nome}</b>`        → nome escapado
 *   html`<td>${raw(badgeSt(s))}</td>`    → HTML preservado
 *
 * Inverte o padrão do projeto: antes era "inseguro a menos que eu
 * lembre do h()", agora é "seguro a menos que eu declare raw()".
 * Arrays são concatenados, o que cobre o caso `${lista.map(...)}`.
 */
export function html(partes, ...vals){
  let out = partes[0];
  for(let i = 0; i < vals.length; i++){
    out += textoDe(vals[i]) + partes[i + 1];
  }
  return out;
}
function textoDe(v){
  if(v == null || v === false) return '';
  if(Array.isArray(v)) return v.map(textoDe).join('');
  if(typeof v === 'object' && v.__raw !== undefined) return v.__raw;
  return h(v);
}

/* ---------------- texto e números ---------------- */
export const dig = v => String(v ?? '').replace(/\D/g, '');
export const opts = obj => Object.entries(obj).map(([value, label]) => ({ value, label }));
export const debounce = (fn, ms = 300) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
/* Remove caracteres que quebram a sintaxe de filtro do PostgREST ou que
   seriam lidos como curinga em ilike. Perde precisão de propósito: é
   melhor buscar demais do que montar um filtro inválido. */
export const safeLike = s => String(s ?? '').replace(/[,()%*\\]/g, ' ').trim();
export const pct = (a, b) => b ? (a / b * 100).toFixed(1).replace('.', ',') + '%' : '—';
export const num = n => Number(n || 0).toLocaleString('pt-BR');
let _uid = 0;
export const uid = p => `${p || 'c'}-${++_uid}`;

/* ---------------- datas ---------------- */
/* Toda data de calendário trafega como 'YYYY-MM-DD' (date do Postgres, sem
   hora). Ao converter para Date usamos sempre o meio-dia local ('T12:00'):
   à meia-noite, uma mudança de horário de verão de -1h joga a data para o
   dia anterior. Não troque por new Date(iso) — isso é lido como UTC e, em
   fuso negativo como o do Brasil, volta um dia. */

export const DIAS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
export const DIAS_LONGO = ['Domingo', 'Segunda-feira', 'Terça-feira', 'Quarta-feira', 'Quinta-feira', 'Sexta-feira', 'Sábado'];

/** Data de hoje no fuso do navegador, em 'YYYY-MM-DD'. */
export const hojeISO = () => new Intl.DateTimeFormat('sv-SE').format(new Date());

export function addDias(iso, n){
  const d = new Date(iso + 'T12:00');
  d.setDate(d.getDate() + n);
  return new Intl.DateTimeFormat('sv-SE').format(d);
}
export function fmtData(d){
  if(!d) return '—';
  const [y, m, dd] = String(d).slice(0, 10).split('-');
  return `${dd}/${m}/${y}`;
}
export function fmtDataHora(d){
  if(!d) return '—';
  return new Date(d).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' });
}
export const fmtHora = t => t ? String(t).slice(0, 5) : '';
export const diaSemana = (iso, longo) => (longo ? DIAS_LONGO : DIAS)[new Date(iso + 'T12:00').getDay()];
export const dataExtenso = iso => `${diaSemana(iso, true)}, ${fmtData(iso)}`;

export function idade(nasc){
  if(!nasc) return '';
  const n = new Date(nasc + 'T12:00'), hj = new Date();
  let a = hj.getFullYear() - n.getFullYear();
  const m = hj.getMonth() - n.getMonth();
  if(m < 0 || (m === 0 && hj.getDate() < n.getDate())) a--;
  return a;
}
/** 'DD/MM/AAAA' → 'AAAA-MM-DD', ou null se a data não existir no calendário. */
export function brParaISO(v){
  const m = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(v || '');
  if(!m) return null;
  const iso = `${m[3]}-${m[2]}-${m[1]}`, d = new Date(iso + 'T12:00');
  return (d.getDate() === +m[1] && d.getMonth() + 1 === +m[2]) ? iso : null;
}
export const inicioMes = () => hojeISO().slice(0, 8) + '01';

/* ---------------- máscaras ---------------- */
export const MASK = {
  cpf:  v => dig(v).slice(0, 11).replace(/(\d{3})(\d)/, '$1.$2').replace(/(\d{3})(\d)/, '$1.$2').replace(/(\d{3})(\d{1,2})$/, '$1-$2'),
  cns:  v => dig(v).slice(0, 15).replace(/(\d{3})(\d)/, '$1 $2').replace(/(\d{3} \d{4})(\d)/, '$1 $2').replace(/(\d{3} \d{4} \d{4})(\d)/, '$1 $2'),
  tel:  v => { v = dig(v).slice(0, 11);
               return v.length > 10 ? v.replace(/(\d{2})(\d{5})(\d{0,4})/, '($1) $2-$3')
                                    : v.replace(/(\d{2})(\d)/, '($1) $2').replace(/(\d{4})(\d)/, '$1-$2'); },
  cep:  v => dig(v).slice(0, 8).replace(/(\d{5})(\d)/, '$1-$2'),
  data: v => dig(v).slice(0, 8).replace(/(\d{2})(\d)/, '$1/$2').replace(/(\d{2}\/\d{2})(\d)/, '$1/$2'),
  guia: v => dig(v).slice(0, 10),
};
export const fCPF = v => v ? MASK.cpf(v) : '—';
export const fCNS = v => v ? MASK.cns(v) : '—';
export const fTel = v => v ? MASK.tel(v) : '—';
export const fCEP = v => v ? MASK.cep(v) : '';
/* CPF e CNS parcialmente ocultos — para listas e resultados de busca */
export const cpfOculto = v => { v = dig(v); return v.length === 11 ? `***.${v.slice(3, 6)}.${v.slice(6, 9)}-**` : '—'; };
export const cnsOculto = v => { v = dig(v); return v.length === 15 ? `*** **** **** ${v.slice(11)}` : '—'; };

/* ---------------- validações ---------------- */
/* Replicadas como constraint no banco (banco-de-dados/migracoes/001-*.sql).
   Se mudar a regra aqui, mude lá também. */

export function validaCNS(v){
  v = dig(v);
  if(v.length !== 15 || !/^[12789]/.test(v)) return false;
  let s = 0;
  for(let i = 0; i < 15; i++) s += Number(v[i]) * (15 - i);
  return s % 11 === 0;
}
export function validaCPF(v){
  v = dig(v);
  if(v.length !== 11 || /^(\d)\1+$/.test(v)) return false;
  for(let t = 9; t < 11; t++){
    let s = 0;
    for(let i = 0; i < t; i++) s += Number(v[i]) * (t + 1 - i);
    if(((s * 10) % 11) % 10 !== Number(v[t])) return false;
  }
  return true;
}
