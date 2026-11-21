-- Arremedo mínimo do ambiente Supabase, só para o CI conseguir aplicar o
-- schema num Postgres limpo e flagrar erro de sintaxe ou de dependência
-- antes de a mudança chegar ao banco do município.
-- Não reproduz o Supabase: não há autenticação real nem JWT aqui.
create extension if not exists pgcrypto;

do $$ begin create role anon;          exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;

create schema if not exists auth;
-- Os campos espelham o que o schema realmente usa de auth.users: o
-- trigger handle_new_user() lê raw_user_meta_data->>'nome'.
create table if not exists auth.users (
  id                  uuid primary key default gen_random_uuid(),
  email               text,
  raw_user_meta_data  jsonb not null default '{}'::jsonb
);
alter table auth.users add column if not exists raw_user_meta_data jsonb not null default '{}'::jsonb;
create or replace function auth.uid() returns uuid
  language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create or replace function auth.role() returns text
  language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'authenticated') $$;

-- Arremedo do Storage, para as políticas de anexo poderem ser criadas e
-- testadas aqui. O Supabase real tem muito mais colunas; estas são as que
-- as políticas do projeto usam.
create schema if not exists storage;
create table if not exists storage.buckets (
  id text primary key, name text not null, public boolean not null default false
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text not null,
  owner uuid,
  created_at timestamptz not null default now()
);
alter table storage.objects enable row level security;
grant select, insert, delete on storage.objects to authenticated;
grant select on storage.buckets to authenticated;
