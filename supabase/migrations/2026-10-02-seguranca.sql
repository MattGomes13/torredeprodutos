-- ============================================================================
-- MIGRAÇÃO DE SEGURANÇA — 2026-10-02
-- Rodar UMA vez no SQL Editor do Supabase (é idempotente: pode rodar de novo
-- sem quebrar nada). Cobre 2 problemas da auditoria de segurança:
--
--   (A) "Desativar usuário" só valia na tela. Agora vale no banco: um usuário
--       com profiles.ativo = false perde TODA permissão (admin/manager/editor/
--       membro de produto), mesmo que ainda consiga fazer login e chamar a API
--       direto. Ele continua conseguindo ler o PRÓPRIO perfil (a tela precisa
--       disso pra deslogá-lo).
--
--   (B) Interdependência entre produtos (aviso/clone laranja):
--       - antes, o navegador mandava o conteúdo do clone pronto (dava pra
--         forjar a origem, injetar qualquer JSON no roadmap de outro produto e
--         copiar valor/observações internas pro outro time);
--       - o clone era identificado só por "<id>_dep", então dois produtos com
--         épico de mesmo código apontando pro mesmo alvo sobrescreviam o aviso
--         um do outro;
--       - depois que o produto alvo salvava o roadmap dele, o código do clone
--         perdia o "_dep" e o aviso não conseguia mais ser removido.
--       Agora o SERVIDOR monta o clone a partir do épico gravado no banco
--       (só campos não sensíveis, SEM valor/observações/atividades), a origem
--       vem do banco (não do navegador), e o aviso é identificado por
--       produto-de-origem + código do épico (dentro do próprio item), não
--       pelo código da linha.
--
-- Também fixa o search_path das funções "security definer" que são recriadas
-- aqui (evita sequestro de função por schema).
--
-- Depois de rodar: republicar a Edge Function admin-reset-password (o código
-- novo está em supabase/functions/admin-reset-password/index.ts) — ela passou
-- a recusar contas desativadas.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- (A) "ativo" passa a valer no banco
-- ---------------------------------------------------------------------------
-- is_admin / is_manager (e, por tabela, can_manage) só valem pra conta ativa.
-- is_stakeholder NÃO muda de propósito: só é usada pelas policies da tabela
-- legada "hubs" ("não-stakeholder pode"), e exigir ativo ali transformaria um
-- stakeholder desativado em "não-stakeholder" (ganharia acesso em vez de perder).
create or replace function is_admin()
returns boolean language sql stable as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin' and ativo);
$$;

create or replace function is_manager()
returns boolean language sql stable as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'manager' and ativo);
$$;

-- editor / membro de produto: a associação só conta se a conta estiver ativa.
create or replace function is_product_editor(p_product_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1
    from product_stakeholders ps
    join profiles pr on pr.id = ps.user_id
    where ps.product_id = p_product_id
      and ps.user_id = auth.uid()
      and ps.pode_editar = true
      and pr.ativo
  );
$$;

create or replace function is_product_member(p_product_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1
    from product_stakeholders ps
    join profiles pr on pr.id = ps.user_id
    where ps.product_id = p_product_id
      and ps.user_id = auth.uid()
      and pr.ativo
  );
$$;


-- ---------------------------------------------------------------------------
-- (B) Interdependência entre produtos — versão segura
-- ---------------------------------------------------------------------------
-- A versão antiga (4 parâmetros, recebia o conteúdo do clone do navegador) é
-- removida: deixá-la viva manteria a brecha mesmo com o código novo.
drop function if exists upsert_dependency_clone(uuid, uuid, text, jsonb);

create or replace function upsert_dependency_clone(
  p_source_product_id uuid,
  p_target_product_id uuid,
  p_source_epic_id text
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_src   jsonb;
  v_nome  text;
  v_slug  text;
  v_clone jsonb;
begin
  -- Quem declara precisa poder editar o produto de ORIGEM (não o alvo).
  if not (can_manage() or is_product_editor(p_source_product_id)) then
    raise exception 'sem permissão para declarar dependência a partir deste produto';
  end if;
  if p_source_product_id = p_target_product_id then
    raise exception 'o produto de destino precisa ser diferente do produto de origem';
  end if;
  if not exists (select 1 from products where id = p_target_product_id) then
    raise exception 'produto de destino não encontrado';
  end if;

  -- O clone é montado a partir do épico JÁ GRAVADO no banco, nunca a partir
  -- de algo que o navegador mande.
  select item into v_src
  from epics
  where product_id = p_source_product_id and epic_id = p_source_epic_id
  limit 1;
  if v_src is null then
    raise exception 'épico de origem não encontrado — salve o épico antes de declarar a dependência';
  end if;

  select name, slug into v_nome, v_slug from products where id = p_source_product_id;

  -- Só campos não sensíveis são compartilhados com o outro produto. Valor
  -- financeiro, observações, atividades, equipe, PO e módulo NÃO vão (o time
  -- do produto alvo pode não ter acesso ao produto de origem).
  v_clone := jsonb_build_object(
    'id',         p_source_epic_id || '@' || v_slug,
    'titulo',     to_jsonb(coalesce(v_src->>'titulo', '')),
    'desc',       to_jsonb(coalesce(v_src->>'desc', '')),
    'tipo',       to_jsonb(coalesce(v_src->>'tipo', '')),
    'status',     to_jsonb(coalesce(v_src->>'status', '')),
    'prioridade', to_jsonb(coalesce(v_src->>'prioridade', '')),
    'quarter',    to_jsonb(coalesce(v_src->>'quarter', 'Backlog')),
    'prog',       case when jsonb_typeof(v_src->'prog') = 'number' then v_src->'prog' else '0'::jsonb end,
    'late',       case when jsonb_typeof(v_src->'late') = 'boolean' then v_src->'late' else 'false'::jsonb end,
    'inicio',     to_jsonb(coalesce(v_src->>'inicio', '')),
    'fim',        to_jsonb(coalesce(v_src->>'fim', '')),
    'entrega',    to_jsonb(coalesce(v_src->>'entrega', '')),
    'novaInicio', to_jsonb(coalesce(v_src->>'novaInicio', '')),
    'novaFim',    to_jsonb(coalesce(v_src->>'novaFim', '')),
    'sprint',     to_jsonb(coalesce(v_src->>'sprint', '')),
    'produto',    to_jsonb(v_nome),
    'esforco',    '""'::jsonb,
    'modulo',     '""'::jsonb,
    'po',         '""'::jsonb,
    'origem',     '""'::jsonb,
    'valor',      '0'::jsonb,
    'tipoValor',  to_jsonb('—'::text),
    'observacoes','[]'::jsonb,
    'atividades', '[]'::jsonb,
    'envolvidos', '{"frontend":0,"backend":0,"qa":0,"outraArea":"","outraQtd":0,"sprints":0}'::jsonb,
    -- a origem vem do BANCO (nome real do produto), nunca do navegador
    'origemDependencia', jsonb_build_object(
      'produtoId',     p_source_product_id,
      'produtoNome',   v_nome,
      'epicoOrigemId', p_source_epic_id
    )
  );

  -- Troca o aviso anterior (se houver) desta origem+épico neste produto alvo.
  -- Identificação pelo conteúdo (origemDependencia), não pelo código da linha:
  -- continua funcionando mesmo depois que o produto alvo regravar o roadmap
  -- inteiro, e não esbarra em épicos de outros produtos com o mesmo código.
  delete from epics
  where product_id = p_target_product_id
    and item->'origemDependencia'->>'produtoId'     = p_source_product_id::text
    and item->'origemDependencia'->>'epicoOrigemId' = p_source_epic_id;

  insert into epics (product_id, epic_id, item)
  values (p_target_product_id, v_clone->>'id', v_clone);
end;
$$;

create or replace function remove_dependency_clone(
  p_source_product_id uuid,
  p_target_product_id uuid,
  p_source_epic_id text
)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (can_manage() or is_product_editor(p_source_product_id)) then
    raise exception 'sem permissão para remover dependência a partir deste produto';
  end if;
  delete from epics
  where product_id = p_target_product_id
    and item->'origemDependencia'->>'produtoId'     = p_source_product_id::text
    and item->'origemDependencia'->>'epicoOrigemId' = p_source_epic_id;
end;
$$;

revoke execute on function upsert_dependency_clone(uuid, uuid, text) from public, anon;
revoke execute on function remove_dependency_clone(uuid, uuid, text) from public, anon;
grant  execute on function upsert_dependency_clone(uuid, uuid, text) to authenticated;
grant  execute on function remove_dependency_clone(uuid, uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- Limpeza única dos avisos que JÁ existem (criados pela versão antiga, que
-- copiava o épico inteiro): tira valor, observações, atividades, equipe etc.
-- do outro produto. Só mexe em linhas que são avisos (têm origemDependencia).
-- Eles voltam a ser atualizados normalmente no próximo salvamento do épico
-- de origem.
-- ---------------------------------------------------------------------------
update epics
set item = (
      item
      - 'dependeDe' - 'divulgar'
      - 'previsibilidade' - 'previsibilidadeDimensionado' - 'previsibilidadeValor'
    )
    || jsonb_build_object(
         'valor', 0,
         'tipoValor', '—',
         'observacoes', '[]'::jsonb,
         'atividades', '[]'::jsonb,
         'esforco', '',
         'modulo', '',
         'po', '',
         'origem', ''
       )
where jsonb_typeof(item->'origemDependencia') = 'object';


-- ---------------------------------------------------------------------------
-- OPCIONAL: a tabela "hubs" é da primeira versão do Hub (upload manual) e não
-- é mais usada por nenhuma tela. Se quiser eliminá-la (menos superfície
-- exposta), descomente a linha abaixo. Irreversível.
-- ---------------------------------------------------------------------------
-- drop table if exists hubs;
