# Operação do Regula Posse

Procedimentos de quem mantém o sistema no ar. Complementa o README, que trata de instalação e desenvolvimento.

## Backup

O Supabase faz backup automático do projeto, com retenção que varia conforme o plano. **Isso não basta**, por dois motivos: a retenção do plano gratuito é curta, e um backup que só existe dentro do mesmo provedor some junto com a conta se ela for suspensa, encerrada ou perdida.

Faça uma cópia própria, fora do Supabase.

### O que copiar

```sh
# 1. Os dados e a estrutura da aplicação
pg_dump "$URL_DO_BANCO" -n public --no-owner --no-privileges -Fc \
  -f "regula-posse-$(date +%Y%m%d).dump"

# 2. As contas de acesso — veja o aviso abaixo, isto não é opcional
psql "$URL_DO_BANCO" -Atc \
  "copy (select id, email, raw_user_meta_data, created_at from auth.users)
   to stdout with csv header" > "auth-users-$(date +%Y%m%d).csv"
```

A string de conexão está no painel do Supabase, em **Project Settings → Database → Connection string → URI**. Ela contém a senha do banco: não a coloque em script versionado nem a cole em conversa; use variável de ambiente.

`ferramentas/backup.sh` faz os dois passos.

### Por que o segundo arquivo não é opcional

Este foi o achado do ensaio de restauração, e é o tipo de coisa que só aparece quando alguém tenta restaurar de verdade:

`perfis.id` referencia `auth.users(id)`. O schema `auth` é gerenciado pelo Supabase e **não vem no dump do `public`**. Restaurando só o `public` num projeto novo, toda linha de `perfis` falha na chave estrangeira — a restauração "dá certo", os dados de paciente e solicitação voltam, **e ninguém consegue entrar no sistema**, porque não há perfil nenhum.

Com o CSV das contas dá para recriar os usuários no Auth do projeto novo e depois reassociar os perfis pelos mesmos UUID.

### Com que frequência

Enquanto o sistema estiver em uso diário, **todo dia**. Guarde em dois lugares diferentes, sendo um fora do computador da secretaria. Mantenha pelo menos as últimas 30 cópias: corrupção de dado às vezes só é percebida semanas depois, e ter só o backup de ontem significa ter só a versão já corrompida.

## Ensaio de restauração

**Faça isto antes de o sistema entrar em uso, e repita a cada seis meses.** Ter backup não é o que importa; o que importa é alguém já ter restaurado um e sabido quanto tempo leva.

O procedimento abaixo foi executado e validado:

```sh
# 1. Crie um projeto Supabase novo, ou um banco local para o ensaio
# 2. Recrie as contas de acesso a partir do CSV, no Auth do projeto novo
#    (Authentication > Users > Add user, mantendo os mesmos e-mails)
# 3. Restaure a aplicação
pg_restore -d "$URL_DO_BANCO_NOVO" --no-owner --no-privileges regula-posse-AAAAMMDD.dump
```

**Erros esperados e inofensivos:**

- `schema "public" already exists` — o banco novo já tem o schema.
- Qualquer erro mencionando `schema "auth"`, `function "uid"`, `function "role"` ou `table "users"` — são objetos do Supabase, que ele gerencia.

**Erro que indica problema de verdade:**

- `violates foreign key constraint "perfis_id_fkey"` — as contas não foram recriadas antes (passo 2). Os perfis não voltaram e ninguém vai conseguir entrar.

**Confira ao final:**

```sql
select count(*) from pacientes;
select count(*) from solicitacoes;
select count(*) from perfis where ativo;      -- precisa ser maior que zero
select count(*) from historico_paciente;      -- a auditoria também tem de voltar
select * from vw_mira limit 1;                -- as views foram recriadas
```

Anote **quanto tempo levou**. Esse número é o que você responde quando perguntarem em quanto tempo o sistema volta.

## Endurecimento do acesso

No painel do Supabase, em **Authentication**:

- **Providers → Email → Confirm email**: mantenha ligado. Sem isso, um e-mail digitado errado vira conta sem dono.
- **Cadastro público desligado.** As contas são criadas uma a uma pela administração, como o README descreve. Confirme que não é possível alguém se cadastrar sozinho.
- **Proteção contra senha vazada** (*leaked password protection*): ligue. O Supabase compara a senha escolhida com bases de senhas vazadas conhecidas e recusa as que aparecem nelas. É gratuito e elimina a pior categoria de senha.
- **Tamanho mínimo de senha**: suba para pelo menos 10 caracteres.
- **Tempo de sessão**: computador de recepção é compartilhado e fica ligado o dia inteiro. Defina expiração de sessão compatível com o turno, não deixe sessão eterna.
- **Autenticação em dois fatores para administrador**: ao menos para as contas com papel `admin`, que podem liberar acessos e ver a auditoria.

Fora do Authentication:

- **Project Settings → Database → senha do banco**: só quem opera o banco precisa dela. Se foi compartilhada alguma vez, troque.
- **Nunca** use a chave `service_role` na aplicação. O `config.js` leva apenas a chave publishable, que é pública por natureza e depende do RLS — é por isso que as políticas de RLS importam tanto neste projeto.

## Retenção

A tela **Administração → Auditoria** mostra os prazos e tem o botão de aplicar. Os prazos ficam na tabela `politica_retencao` e podem ser ajustados pelo administrador.

A regra vale **só para log operacional**: erro de navegador, tentativa de consulta pública e log de acesso. Solicitação, histórico e cadastro de paciente são registro assistencial e nunca são apagados por ali — o prazo de guarda de prontuário é matéria de resolução do Conselho Federal de Medicina e de legislação de arquivo público, e é decisão do município com o jurídico.

Vale agendar a limpeza para rodar sozinha (`pg_cron`, no Supabase) em vez de depender de alguém lembrar.

## Quando algo der errado

1. **Administração → Auditoria** mostra quem alterou e quem acessou cadastro de paciente.
2. A tabela `erros` guarda os erros de navegador, com rota e mensagem. Sequências de seis dígitos ou mais vêm mascaradas de propósito, porque mensagem de erro do Postgres traz o valor que violou a restrição e esse valor pode ser um CPF.
3. `consultas_publicas` registra as tentativas de acompanhamento. Muitas tentativas sem sucesso no mesmo protocolo, ou muitos protocolos diferentes em pouco tempo, é sinal de varredura.
