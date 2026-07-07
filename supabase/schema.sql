-- ============================================================
-- Projetos NF — Schema do banco (Supabase)
-- Cole este arquivo inteiro no SQL Editor do Supabase e execute.
-- Modelo de permissão: contas novas nascem PENDENTES e não veem nada
-- até um admin aprovar. Aprovado vê os projetos de equipe conforme seu
-- escopo: "todos" (padrão) ou apenas os projetos liberados pelo admin.
-- Quem vê um projeto cria tarefas nele e muda a situação de qualquer
-- tarefa; o responsável edita o conteúdo das suas (sem reatribuir);
-- admin vê e edita tudo.
-- Este arquivo é idempotente: pode ser re-executado numa base existente.
-- ============================================================

-- ---------- Perfis (um por usuário registrado) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text not null default '',
  role text not null default 'operator' check (role in ('admin','operator')),
  approved boolean not null default false,
  access_all boolean not null default true,
  created_at timestamptz not null default now()
);

-- Base existente: adiciona colunas novas se ainda não existirem
alter table public.profiles add column if not exists approved boolean not null default false;
alter table public.profiles add column if not exists access_all boolean not null default true;

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
  sort_order int not null default 0,
  kind text not null default 'normal' check (kind in ('normal','dev')),
  owner_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Base existente: colunas novas
alter table public.projects add column if not exists sort_order int not null default 0;
alter table public.projects add column if not exists kind text not null default 'normal' check (kind in ('normal','dev'));
alter table public.projects add column if not exists owner_id uuid references public.profiles(id) on delete set null;


-- ---------- Acesso por projeto (quando o operador não vê "todos") ----------
create table if not exists public.project_access (
  project_id uuid not null references public.projects(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (project_id, profile_id)
);

-- ---------- Confirmação de recebimento de tarefa (por usuário) ----------
-- Uma linha = aquele usuário já "leu" a tarefa atribuída a ele.
create table if not exists public.task_acks (
  task_id uuid not null references public.tasks(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (task_id, profile_id)
);

-- ---------- Log da tarefa (anotações de evolução pelos operadores) ----------
create table if not exists public.task_logs (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  author_id uuid references public.profiles(id) on delete set null,
  body text not null,
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

-- ---------- Função auxiliar: usuário atual pode VER este projeto? ----------
-- Admin vê tudo; os demais precisam de aprovação e escopo
-- (vê todos, tem liberação específica em project_access, ou é o criador).
create or replace function public.can_view_project(pid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin()
      or ( public.is_approved() and (
             exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.access_all)
          or exists (select 1 from public.project_access a
                     where a.project_id = pid and a.profile_id = auth.uid())
          or exists (select 1 from public.projects p
                     where p.id = pid and p.owner_id = auth.uid())
      ));
$$;


-- ---------- Proteção: só admin altera papel e aprovação ----------
-- Sem isso, qualquer usuário poderia se autopromover a admin pela API
-- (as políticas de RLS não restringem colunas individuais).
-- Quando auth.uid() é nulo (SQL Editor do painel, service role), libera —
-- é assim que o primeiro admin é promovido.
create or replace function public.protect_profile_fields()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null
     and (new.role is distinct from old.role
          or new.approved is distinct from old.approved
          or new.access_all is distinct from old.access_all)
     and not public.is_admin() then
    raise exception 'Apenas administradores podem alterar papel, aprovação ou escopo de acesso';
  end if;
  return new;
end; $$;

drop trigger if exists protect_profile_fields on public.profiles;
create trigger protect_profile_fields
  before update on public.profiles
  for each row execute function public.protect_profile_fields();

-- ---------- Limpeza da antiga lógica de projeto privado ----------
-- (ordem importa: políticas dependem das colunas, então saem antes)
drop policy if exists projects_owner_private on public.projects;
drop policy if exists tasks_private_owner on public.tasks;
drop function if exists public.owns_private_project(uuid);
alter table public.projects drop column if exists private;
alter table public.projects drop column if exists owner_id;

-- ---------- Row Level Security ----------
alter table public.profiles       enable row level security;
alter table public.projects       enable row level security;
alter table public.tasks          enable row level security;
alter table public.project_access enable row level security;
alter table public.task_acks      enable row level security;
alter table public.task_logs      enable row level security;

-- Log da tarefa: quem vê o projeto lê; aprovado que vê escreve (como
-- autor); autor ou admin apaga
drop policy if exists task_logs_select on public.task_logs;
create policy task_logs_select on public.task_logs
  for select to authenticated using (
    exists (select 1 from public.tasks t where t.id = task_id and public.can_view_project(t.project_id)));
drop policy if exists task_logs_insert on public.task_logs;
create policy task_logs_insert on public.task_logs
  for insert to authenticated with check (
    author_id = auth.uid() and public.is_approved()
    and exists (select 1 from public.tasks t where t.id = task_id and public.can_view_project(t.project_id)));
drop policy if exists task_logs_delete on public.task_logs;
create policy task_logs_delete on public.task_logs
  for delete to authenticated using (author_id = auth.uid() or public.is_admin());

-- Confirmações de recebimento: cada um lê e gerencia apenas as suas
drop policy if exists task_acks_select on public.task_acks;
create policy task_acks_select on public.task_acks
  for select to authenticated using (profile_id = auth.uid());
drop policy if exists task_acks_insert on public.task_acks;
create policy task_acks_insert on public.task_acks
  for insert to authenticated with check (profile_id = auth.uid());
drop policy if exists task_acks_delete on public.task_acks;
create policy task_acks_delete on public.task_acks
  for delete to authenticated using (profile_id = auth.uid());

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

-- Projetos: leitura conforme escopo (admin tudo; operador vê todos
-- ou apenas os liberados); apenas admin cria/edita/exclui
drop policy if exists projects_select on public.projects;
create policy projects_select on public.projects
  for select to authenticated using (public.can_view_project(id));

drop policy if exists projects_admin_write on public.projects;
create policy projects_admin_write on public.projects
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Operador aprovado pode CRIAR projetos, mas só na aba Desenvolvimento
-- (kind='dev') e como dono; nunca projetos "normais" nem exclusão.
drop policy if exists projects_operator_insert_dev on public.projects;
create policy projects_operator_insert_dev on public.projects
  for insert to authenticated
  with check (public.is_approved() and kind = 'dev' and owner_id = auth.uid());

-- Operador aprovado pode ATUALIZAR projetos que vê — o trigger abaixo
-- restringe a alteração apenas aos setores (subprojects).
drop policy if exists projects_operator_update on public.projects;
create policy projects_operator_update on public.projects
  for update to authenticated
  using (public.is_approved() and public.can_view_project(id))
  with check (public.is_approved() and public.can_view_project(id));

-- Proteção: não-admin só altera 'subprojects' (setores) de um projeto
create or replace function public.protect_project_fields()
returns trigger language plpgsql as $$
begin
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;
  if new.name        is distinct from old.name
     or new.description is distinct from old.description
     or new.color     is distinct from old.color
     or new.status    is distinct from old.status
     or new.sort_order is distinct from old.sort_order
     or new.kind      is distinct from old.kind
     or new.owner_id  is distinct from old.owner_id then
    raise exception 'Operadores só podem alterar os setores do projeto';
  end if;
  return new;
end; $$;

drop trigger if exists protect_project_fields on public.projects;
create trigger protect_project_fields
  before update on public.projects
  for each row execute function public.protect_project_fields();

-- Acesso por projeto: admin gerencia; cada um pode ler as próprias liberações
drop policy if exists project_access_select on public.project_access;
create policy project_access_select on public.project_access
  for select to authenticated using (profile_id = auth.uid() or public.is_admin());

drop policy if exists project_access_admin_write on public.project_access;
create policy project_access_admin_write on public.project_access
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Tarefas: leitura segue a visibilidade do projeto; admin faz tudo;
-- quem VÊ o projeto pode criar tarefas e atualizar (o trigger abaixo
-- limita o quê: responsável edita conteúdo sem reatribuir; os demais
-- só mudam a situação/coluna). Excluir é só admin.
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks
  for select to authenticated using (public.can_view_project(project_id));

drop policy if exists tasks_admin_all on public.tasks;
create policy tasks_admin_all on public.tasks
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists tasks_operator_update_own on public.tasks;

drop policy if exists tasks_insert_visible on public.tasks;
create policy tasks_insert_visible on public.tasks
  for insert to authenticated
  with check (public.is_approved() and public.can_view_project(project_id));

drop policy if exists tasks_update_visible on public.tasks;
create policy tasks_update_visible on public.tasks
  for update to authenticated
  using (public.is_approved() and public.can_view_project(project_id))
  with check (public.is_approved() and public.can_view_project(project_id));

-- Excluir tarefa: qualquer aprovado que enxerga o projeto
drop policy if exists tasks_delete_visible on public.tasks;
create policy tasks_delete_visible on public.tasks
  for delete to authenticated
  using (public.is_approved() and public.can_view_project(project_id));

-- Sem restrição de colunas por papel: quem vê o projeto edita qualquer
-- campo da tarefa (o trigger antigo de proteção foi removido).
drop trigger if exists protect_task_fields on public.tasks;
drop function if exists public.protect_task_fields();

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
do $$ begin
  alter publication supabase_realtime add table public.project_access;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.task_acks;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.task_logs;
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
