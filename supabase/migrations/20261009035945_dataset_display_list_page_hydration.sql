-- Database #801: count/page narrow identities before reading TOAST-backed names.
-- Preserve the #799 response, exact totals, sort, search and authorization contract.
begin;
create or replace function private.dataset_display_list(
  p_kind text,p_visibility text,p_query text,p_page_size integer,p_page integer,p_candidates boolean
) returns jsonb language plpgsql stable security definer
set search_path = '' set statement_timeout = '15s' as $$
declare v_result jsonb; v_search_filter text := '';
begin
  if auth.uid() is null then raise exception using errcode='28000',message='authentication required'; end if;
  if p_candidates then perform private.dataset_display_require_manager(); end if;
  if p_kind is null or p_kind not in ('all','lifecyclemodel','process','flow','flowproperty','unitgroup','source','contact')
    or p_visibility is null or p_visibility not in ('all','visible','hidden')
    or p_query is null or octet_length(p_query)>512
    or p_page_size is null or p_page_size not between 1 and 100
    or p_page is null or p_page not between 1 and 1000000 then
    raise exception using errcode='22023',message='invalid display list filters or pagination';
  end if;

  -- Parameter-bound custom plans prune unused kinds and visibility branches.
  -- Empty search must not retain a name expression in the candidate scan.
  -- Only this fixed SQL literal is concatenated, never caller input.
  if p_query <> '' then
    v_search_filter := ' and (strpos(lower(coalesce(c.name::text,'''')),lower($3))>0 or strpos(c.dataset_id::text,lower($3))>0)';
  end if;
  execute $query$
    with eligible as materialized (
      select c.dataset_kind,c.dataset_id,c.dataset_version,
        coalesce(s.is_visible,false) as is_visible
      from private.dataset_display_catalog c
      left join private.dataset_display_settings s using(dataset_kind,dataset_id,dataset_version)
      where ($1='all' or c.dataset_kind=$1)
        and ($6 or s.is_visible)
        and ($2='all' or ($2='visible' and s.is_visible)
          or ($2='hidden' and not coalesce(s.is_visible,false)))
    $query$ || v_search_filter || $query$
    ), page as materialized (
      select * from eligible order by dataset_kind,dataset_id,dataset_version desc
      limit $4 offset ($5::bigint-1)*$4
    ), hydrated as (
      select page.dataset_kind,page.dataset_id,page.dataset_version,
        case when octet_length(c.name::text)<=16384 then c.name else null end as name,
        page.is_visible
      from page
      -- Fence the correlated exact lookup against a full-card hash join.
      -- Only the bounded page reads names, including deep/empty pages.
      cross join lateral (
        select source.name from private.dataset_display_catalog source
        where source.dataset_kind=page.dataset_kind
          and source.dataset_id=page.dataset_id
          and source.dataset_version=page.dataset_version
        offset 0
      ) c
    )
    select jsonb_build_object('data',coalesce((select jsonb_agg(
      case when $6 then to_jsonb(hydrated) else to_jsonb(hydrated)-'is_visible' end
      order by dataset_kind,dataset_id,dataset_version desc) from hydrated),'[]'::jsonb),
      'total',(select count(*) from eligible))
  $query$ into v_result using p_kind,p_visibility,p_query,p_page_size,p_page,p_candidates;
  return v_result;
end; $$;
-- CREATE OR REPLACE preserves owner and the existing closed private ACL.
commit;
