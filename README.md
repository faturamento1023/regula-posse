# Regula Posse
Aplicação web de regulação municipal com login por e-mail e senha e Supabase Auth. Sirva a pasta em HTTPS. Configure em config.js a URL do projeto e sua chave pública publishable. Use apenas a chave de cliente. No banco dedicado vazio, aplique banco-de-dados/schema.sql uma vez. Desabilite cadastro público no Supabase Auth e crie as contas individuais em Authentication > Users > Add user > Create new user.

## Liberação
Uma conta nova recebe perfil inativo. O operador autorizado do banco deve conferir o UUID do primeiro administrador em Authentication e executar no SQL Editor, substituindo o UUID:
```sql
update public.perfis set papel='admin', ativo=true where id='UUID-DA-CONTA'::uuid;
```
O administrador cadastra unidades e procedimentos e libera as demais contas em Usuários → Somente inativos → Editar. Selecione o papel, atribua a unidade e marque Acesso ativo.

| Perfil | Atribuição |
|---|---|
| Administrador | Gerencia usuários e unidades e tem acesso aos fluxos da central. |
| Regulador | Analisa os pedidos, autoriza, devolve e nega. Também opera a agenda central. |
| Agendador | Organiza filas e vagas, agenda e confirma atendimentos e gerencia cadastros operacionais. |
| Atendente | Registra pacientes e pedidos, corrige devoluções e agenda pedidos da unidade conforme a regra do procedimento. |
| Executante | Consulta as guias e confirma realização ou falta dos atendimentos da unidade vinculada. |

O pacote não inclui pacientes, unidades, procedimentos ou usuários fictícios. A URL e a chave pública do projeto ficam no config.js após criar o projeto Supabase. A senha individual é definida no Supabase Auth e nunca deve ser colocada no repositório.

## Catálogo SIGTAP

O banco contém 5.068 códigos e nomes da competência **11/2026**, extraídos de `TabelaUnificada_202611_v2611051737.zip` (espelho do FTP do DATASUS). A origem, o hash SHA-256 e a contagem constam em [data/sigtap-202611/manifesto.json](data/sigtap-202611/manifesto.json). O arquivo `tb_procedimento.txt` é de largura fixa: código nas posições 1–10 e nome nas posições 11–260, em Latin-1. O fluxo de extração está em `.github/workflows/preparar-sigtap.yml`, e os lotes SQL em `data/sigtap-202611/`.

Todos os procedimentos importados começam **inativos**. Em **Procedimentos**, selecione **Somente inativos**, busque por nome ou código, edite o tipo e a exigência de regulação, e ative somente os oferecidos pelo município. Cadastre os locais e associe os procedimentos habilitados a eles. Nenhum procedimento foi liberado automaticamente para agendamento.

Para atualizar uma competência futura, altere a URL e a competência no workflow, execute-o, revise o manifesto e aplique os novos lotes SQL. A importação preserva o campo `ativo`, o tipo, a especialidade e a regra de regulação dos códigos já existentes.
