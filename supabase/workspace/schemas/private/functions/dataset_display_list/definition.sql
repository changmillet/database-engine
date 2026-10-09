CREATE OR REPLACE FUNCTION "private"."dataset_display_list"("p_kind" "text", "p_visibility" "text", "p_query" "text", "p_page_size" integer, "p_page" integer, "p_candidates" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '15s'
    AS $$
declare v_result jsonb;
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
  with eligible as materialized (
    select c.dataset_kind,c.dataset_id,c.dataset_version,
      case when octet_length(c.name::text)<=16384 then c.name else null end as name,
      coalesce(s.is_visible,false) as is_visible
    from private.dataset_display_catalog c
    left join private.dataset_display_settings s using(dataset_kind,dataset_id,dataset_version)
    where (p_kind='all' or c.dataset_kind=p_kind)
      and (p_candidates or s.is_visible)
      and (p_visibility='all' or (p_visibility='visible' and s.is_visible) or (p_visibility='hidden' and not coalesce(s.is_visible,false)))
      and (p_query='' or strpos(lower(coalesce(c.name::text,'')),lower(p_query))>0 or strpos(c.dataset_id::text,lower(p_query))>0)
  ), page as (
    select * from eligible order by dataset_kind,dataset_id,dataset_version desc
    limit p_page_size offset (p_page::bigint-1)*p_page_size
  )
  select jsonb_build_object('data',coalesce((select jsonb_agg(
    case when p_candidates then to_jsonb(page) else to_jsonb(page)-'is_visible' end
    order by dataset_kind,dataset_id,dataset_version desc) from page),'[]'::jsonb),
    'total',(select count(*) from eligible)) into v_result;
  return v_result;
end; $$;

ALTER FUNCTION "private"."dataset_display_list"("p_kind" "text", "p_visibility" "text", "p_query" "text", "p_page_size" integer, "p_page" integer, "p_candidates" boolean) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_display_list"("p_kind" "text", "p_visibility" "text", "p_query" "text", "p_page_size" integer, "p_page" integer, "p_candidates" boolean) FROM PUBLIC;
