-- Arremedo mínimo do ambiente Supabase, só para o CI conseguir aplicar o
-- schema num Postgres limpo e flagrar erro de sintaxe ou de dependência
-- antes de a mudança chegar ao banco do município.
-- Não reproduz o Supabase: não há autenticação real nem JWT aqui.
create extension if not exists pgcrypto;

do $$ begin create role anon;          exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;

create schema if not exists auth;
create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text
);
create or replace function auth.uid() returns uuid
  language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create or replace function auth.role() returns text
  language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'authenticated') $$;
