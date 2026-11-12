-- =====================================================================
-- Arpejo Perfumaria: métricas do site (visitas e cliques)
-- Como usar: Supabase → SQL Editor → New query → cole tudo → Run.
-- Pode rodar mais de uma vez sem problema.
-- =====================================================================

-- 1) Tabela de eventos (cada visita e cada clique vira uma linha)
create table if not exists public.eventos (
  id           bigint generated always as identity primary key,
  tipo         text not null check (tipo in ('visita', 'clique_encomendar', 'clique_whatsapp', 'clique_instagram')),
  perfume_id   text check (char_length(perfume_id)   <= 64),
  perfume_nome text check (char_length(perfume_nome) <= 80),
  visitante    text check (char_length(visitante)    <= 64),   -- código anônimo guardado no navegador
  dispositivo  text check (dispositivo in ('mobile', 'desktop')),
  criado_em    timestamptz not null default now()
);

create index if not exists eventos_criado_em_idx      on public.eventos (criado_em);
create index if not exists eventos_tipo_criado_em_idx on public.eventos (tipo, criado_em);

-- 2) Segurança: visitantes só conseguem REGISTRAR eventos; só o admin logado consegue LER
alter table public.eventos enable row level security;

drop policy if exists "visitantes registram eventos" on public.eventos;
create policy "visitantes registram eventos"
  on public.eventos for insert to anon, authenticated with check (true);

drop policy if exists "admin le eventos" on public.eventos;
create policy "admin le eventos"
  on public.eventos for select to authenticated using (true);

-- 3) Função que o painel chama para montar os números (respeita as regras acima:
--    para quem não está logado ela devolve tudo zerado)
create or replace function public.metricas(dias int default 30)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  with base as (
    select *
    from public.eventos
    where criado_em >= (
      ((now() at time zone 'America/Sao_Paulo')::date - (greatest(1, least(dias, 365)) - 1))::timestamp
      at time zone 'America/Sao_Paulo'
    )
  )
  select jsonb_build_object(
    'visitas',            (select count(*) from base where tipo = 'visita'),
    'visitantes',         (select count(distinct visitante) from base where tipo = 'visita'),
    'cliques_encomendar', (select count(*) from base where tipo = 'clique_encomendar'),
    'cliques_whatsapp',   (select count(*) from base where tipo = 'clique_whatsapp'),
    'cliques_instagram',  (select count(*) from base where tipo = 'clique_instagram'),
    'mobile',             (select count(*) from base where tipo = 'visita' and dispositivo = 'mobile'),
    'por_dia', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.dia), '[]'::jsonb)
      from (
        select (criado_em at time zone 'America/Sao_Paulo')::date           as dia,
               count(*) filter (where tipo = 'visita')                      as visitas,
               count(*) filter (where tipo = 'clique_encomendar')           as cliques
        from base
        group by 1
      ) x
    ),
    'por_perfume', (
      select coalesce(jsonb_agg(to_jsonb(y) order by y.cliques desc, y.nome), '[]'::jsonb)
      from (
        select perfume_id                                              as id,
               (array_agg(perfume_nome order by criado_em desc))[1]    as nome,
               count(*)                                                as cliques
        from base
        where tipo = 'clique_encomendar' and perfume_id is not null
        group by perfume_id
      ) y
    )
  );
$$;

revoke all on function public.metricas(int) from public, anon;
grant execute on function public.metricas(int) to authenticated;
