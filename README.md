# Projetos NF

Gerenciador de projetos da Quanta: quadro Kanban com projetos, setores (subprojetos), operadores, prazos e agenda — acessível pelo navegador, com login por email e senha e sincronização em tempo real para a equipe.

## Estrutura

| Arquivo | O que é |
|---|---|
| `index.html` | **Versão online** (multiusuário). Front-end completo num único arquivo, ligado ao Supabase (banco + autenticação + tempo real). É o arquivo que vai para a hospedagem. |
| `organizador-local.html` | **Versão local** (uso individual). Guarda os dados no navegador (localStorage), funciona offline, sem login. Útil como sandbox. |
| `supabase/schema.sql` | Criação do banco: tabelas, trigger de perfis e as políticas de permissão (Row Level Security). |

## Modelo de permissões

Todos os usuários autenticados **veem tudo**. Cada **operador** só consegue atualizar as tarefas em que é o responsável (concluir, mover de coluna, editar conteúdo — sem reatribuir projeto/setor/responsável). O **admin** cria, edita e exclui qualquer coisa: projetos, setores, tarefas e atribuições. As regras são aplicadas no servidor (RLS), não apenas escondidas na interface.

## Como publicar (do zero)

1. **Supabase** — crie um projeto em [supabase.com](https://supabase.com). No *SQL Editor*, execute o conteúdo de `supabase/schema.sql`.
2. **Credenciais** — em *Settings → API*, copie a Project URL e a publishable key e cole nas duas constantes no topo do script de `index.html` (`SUPABASE_URL` e `SUPABASE_ANON_KEY`).
3. **Hospedagem** — qualquer serviço de site estático serve. Duas opções fáceis:
   - **GitHub Pages**: neste repositório, vá em *Settings → Pages → Source: Deploy from a branch → main / root*. O site sobe em `https://SEU-USUARIO.github.io/NOME-DO-REPO/`.
   - **Netlify / Vercel / Cloudflare Pages**: arraste o `index.html` (ou conecte o repositório para deploy automático a cada push).
4. **Primeiro acesso** — abra o site, crie sua conta ("Criar conta"). Depois, no SQL Editor do Supabase, torne-se admin (uma única vez):
   ```sql
   update public.profiles set role = 'admin' where email = 'seu@email.com';
   ```
5. **Equipe** — cada operador cria a própria conta na tela de login com o email de trabalho. Ao entrar, já aparece na Equipe e pode receber tarefas.

## Sobre a chave no código

A *publishable key* do Supabase é pública por design — ela identifica o projeto, não concede privilégios. Toda a segurança vem das políticas RLS do `schema.sql`. Ainda assim, se quiser trocá-la algum dia, gere uma nova em *Settings → API* e atualize o `index.html`.

## Rodando a versão local

```bash
python3 -m http.server 8000
# abra http://localhost:8000/organizador-local.html
```

## Stack

HTML/CSS/JS puro num único arquivo por versão (sem build), [supabase-js v2](https://supabase.com/docs/reference/javascript) via CDN, Supabase (Postgres + Auth + Realtime) como backend.
