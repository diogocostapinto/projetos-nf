-- ============================================================
-- Projetos NF — Schema do banco (Supabase)
-- Cole este arquivo inteiro no SQL Editor do Supabase e execute.
-- Modelo de permissão: contas novas nascem PENDENTES e não veem nada
-- até um admin aprovar; aprovados veem tudo; operador edita apenas as
-- próprias tarefas; admin aprova/revoga acessos e edita tudo.
-- Este arquivo é idempotente: pode ser re-executado numa base existente.
-- ============================================================

-- ---------- Perfis (um por usuário registrado) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text not null default '',
  role text not null default 'operator' check (role in ('admin','operator')),
  approved boolean not null default false,
  created_at timestamptz not null default now()
);

-- Base existente: adiciona a coluna de aprovação se ainda não existir
alter table public.profiles add column if not exists approved boolean not null default false;

-- Cria o perfil automaticamente quando alguém se registra
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)));
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Projetos (setores ficam em jsonb dentro do projeto) ----------
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text not null default '',
  color text not null default '#2F6F5E',
  status text not null default 'ativo' check (status in ('ativo','pausado','concluido')),
  subprojects jsonb not null default '[]',
  created_at timestamptz not null default now()
);

-- ---------- Tarefas ----------
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  subproject_id text not null default '',
  title text not null,
  description text not null default '',
  due date,
  prio text not null default 'media' check (prio in ('alta','media','baixa')),
  col text not null default 'todo' check (col in ('todo','doing','done')),
  operator_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------- Função auxiliar: usuário atual é admin? ----------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- ---------- Função auxiliar: usuário atual foi aprovado? ----------
-- Admin conta como aprovado automaticamente.
create or replace function public.is_approved()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and (approved or role = 'admin'));
$$;

-- ---------- Proteção: só admin altera papel e aprovação ----------
-- Sem isso, qualquer usuário poderia se autopromover a admin pela API
-- (as políticas de RLS não restringem colunas individuais).
create or replace function public.protect_profile_fields()
returns trigger language plpgsql as $$
begin
  if (new.role is distinct from old.role or new.approved is distinct from old.approved)
     and not public.is_admin() then
    raise exception 'Apenas administradores podem alterar papel ou aprovação';
  end if;
  return new;
end; $$;

drop trigger if exists protect_profile_fields on public.profiles;
create trigger protect_profile_fields
  before update on public.profiles
  for each row execute function public.protect_profile_fields();

-- ---------- Row Level Security ----------
alter table public.profiles enable row level security;
alter table public.projects enable row level security;
alter table public.tasks    enable row level security;

-- Perfis: cada um vê o próprio (para saber se está pendente);
-- aprovados veem todos; admin edita qualquer um
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_approved());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());

-- Projetos: apenas aprovados leem; apenas admin cria/edita/exclui
drop policy if exists projects_select on public.projects;
create policy projects_select on public.projects
  for select to authenticated using (public.is_approved());

drop policy if exists projects_admin_write on public.projects;
create policy projects_admin_write on public.projects
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Tarefas: apenas aprovados leem; admin faz tudo; operador ATUALIZA apenas as suas
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks
  for select to authenticated using (public.is_approved());

drop policy if exists tasks_admin_all on public.tasks;
create policy tasks_admin_all on public.tasks
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists tasks_operator_update_own on public.tasks;
create policy tasks_operator_update_own on public.tasks
  for update to authenticated
  using (operator_id = auth.uid() and public.is_approved())
  with check (operator_id = auth.uid() and public.is_approved());

-- ---------- Tempo real ----------
-- Faz o app de todos atualizar sozinho quando algo muda
do $$ begin
  alter publication supabase_realtime add table public.projects;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.tasks;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null; end $$;

-- ============================================================
-- PASSO FINAL (manual, uma única vez):
-- Depois de VOCÊ criar a sua conta pela tela de login do app,
-- rode a linha abaixo com o SEU email para virar admin
-- (admin já conta como aprovado):
--
--   update public.profiles set role = 'admin', approved = true where email = 'seu@email.com';
--
-- Se já existiam operadores cadastrados antes desta versão,
-- aprove-os pela tela Equipe do app ou por SQL:
--
--   update public.profiles set approved = true where email = 'operador@empresa.com';
-- ============================================================
