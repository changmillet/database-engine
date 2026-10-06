-- Database #783: remove redundant materialization on query/filter-free reads.
-- Preserve exact public-version totals, forced RLS, signatures, owners, ACLs,
-- function budgets and all filtered/lexical branches. No index or writer change.

begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
-- Use the existing NOLOGIN owner for DDL, restoring membership and schema
-- privileges exactly before commit, as in the preceding bounded-reader cutover.
do $portal_empty_acl_begin$
declare before_grant jsonb;
begin
  select pg_catalog.jsonb_build_object('admin',m.admin_option,'inherit',m.inherit_option,'set',m.set_option)
    into before_grant from pg_catalog.pg_auth_members m
    where m.roleid='portal_public_executor'::regrole and m.member='postgres'::regrole
      and m.grantor=current_user::regrole;
  perform pg_catalog.set_config('portal_empty_cutover.postgres_grant',coalesce(before_grant,'null'::jsonb)::text,true);
  perform pg_catalog.set_config('portal_empty_cutover.create_added',
    (not pg_catalog.has_schema_privilege('portal_public_executor','private','CREATE'))::text,true);
  grant portal_public_executor to postgres with set true;
  if pg_catalog.current_setting('portal_empty_cutover.create_added')::boolean then
    grant create on schema private to portal_public_executor;
  end if;
end;
$portal_empty_acl_begin$;
set local role portal_public_executor;

CREATE OR REPLACE FUNCTION "private"."portal_navigation_impl_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor_node_id" "text", "p_limit" integer, "p_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "statement_timeout" TO '8s'
    SET "work_mem" TO '32MB'
    AS $$
declare
  v_parent jsonb;
  v_ancestors jsonb:='[]';
  v_nodes jsonb;
  v_totals jsonb;
  v_next text;
  v_result jsonb;
  v_after_code text;
  v_trimmed boolean:=false;
begin
  perform private.assert_portal_navigation_contract_v1();
  if p_parent_node_id is not null and not exists (
    select 1 from private.portal_navigation_node_v1 n
    where n.node_id=p_parent_node_id and n.dimension=p_dimension
      and (n.source_file is not null or n.node_id in ('class:isic','class:cpc','class:elementary','geo:unmapped')
        or exists(select 1 from private.portal_navigation_membership_v1 m where m.node_id=n.node_id))
  ) then raise exception using errcode='22023',message='invalid portal request'; end if;
  if p_cursor_node_id is not null then
    select n.code into v_after_code from private.portal_navigation_node_v1 n
    where n.node_id=p_cursor_node_id and n.dimension=p_dimension
      and n.parent_node_id is not distinct from p_parent_node_id;
    if not found then raise exception using errcode='22023',message='invalid portal request'; end if;
  end if;

  with matched as materialized (
    select * from private.portal_navigation_matched_versions_v1('all',p_query,p_filters)
  ), children as materialized (
    select n.* from private.portal_navigation_node_v1 n
    where n.dimension=p_dimension and n.parent_node_id is not distinct from p_parent_node_id
      and (n.source_file is not null or n.node_id in ('class:isic','class:cpc','class:elementary','geo:unmapped') or exists (
        select 1 from private.portal_navigation_membership_v1 m
        where m.node_id=n.node_id and (p_kind='all' or m.dataset_kind=p_kind)
          and ((p_query='' and p_filters='{}'::jsonb)
            or (m.dataset_kind,m.id,m.version) in (select dataset_kind,id,version from matched))))
      and (p_dimension<>'classification' or p_kind='all' or n.taxonomy not in ('isic','cpc','elementary')
        or (p_kind='process' and n.taxonomy='isic') or (p_kind='flow' and n.taxonomy in ('cpc','elementary')))
      and (p_cursor_node_id is null or (n.code collate "C",n.node_id collate "C")>(v_after_code collate "C",p_cursor_node_id collate "C"))
    order by n.code collate "C",n.node_id collate "C" limit p_limit+1
  ), targets as materialized (
    select * from children
    union all
    select n.* from private.portal_navigation_node_v1 n where n.node_id=p_parent_node_id
  ), counted as materialized (
    select m.node_id,count(*) as count,count(*) filter(where m.direct) as direct_count
    from private.portal_navigation_membership_v1 m
    where m.dimension=p_dimension and (p_kind='all' or m.dataset_kind=p_kind)
      and ((p_query='' and p_filters='{}'::jsonb)
        or (m.dataset_kind,m.id,m.version) in (select dataset_kind,id,version from matched))
      and m.node_id in(select n.node_id from targets n)
    group by m.node_id
  ), decorated as materialized (
    select n.node_id,n.code,jsonb_build_object(
      'nodeId',n.node_id,'parentNodeId',n.parent_node_id,'code',n.code,'taxonomy',n.taxonomy,
      'count',coalesce(c.count,0),'directCount',coalesce(c.direct_count,0),
      'hasChildren',exists(select 1 from private.portal_navigation_node_v1 child where child.parent_node_id=n.node_id
        and (child.source_file is not null or exists(select 1 from private.portal_navigation_membership_v1 m where m.node_id=child.node_id)))
    ) as value from targets n left join counted c on c.node_id=n.node_id
  ), paged as (
    select d.*,row_number() over(order by d.code collate "C",d.node_id collate "C") as rn
    from decorated d where d.node_id is distinct from p_parent_node_id
  ) select
    coalesce((select jsonb_agg(value order by rn) from paged where rn<=p_limit),'[]'::jsonb),
    (select case when count(*)>p_limit then (array_agg(node_id order by rn))[p_limit] else null end from paged),
    (select value from decorated where node_id=p_parent_node_id),
    (case when p_query='' and p_filters='{}'::jsonb then
      (select jsonb_build_object('process',count(*) filter(where dataset_kind='process'),'flow',count(*) filter(where dataset_kind='flow'))
       from private.portal_navigation_versions_v1)
     else (select jsonb_build_object('process',count(*) filter(where dataset_kind='process'),'flow',count(*) filter(where dataset_kind='flow')) from matched) end)
  into v_nodes,v_next,v_parent,v_totals;

  with recursive ancestors as (
    select n.node_id,n.parent_node_id,n.code,n.taxonomy,1 as depth
    from private.portal_navigation_node_v1 n
    where n.node_id=(select p.parent_node_id from private.portal_navigation_node_v1 p where p.node_id=p_parent_node_id)
    union all
    select n.node_id,n.parent_node_id,n.code,n.taxonomy,a.depth+1
    from ancestors a join private.portal_navigation_node_v1 n on n.node_id=a.parent_node_id
    where a.depth<32
  ) select coalesce(jsonb_agg(jsonb_build_object('nodeId',node_id,'parentNodeId',parent_node_id,'code',code,'taxonomy',taxonomy) order by depth desc),'[]'::jsonb)
    into v_ancestors from ancestors;

  loop
    v_result:=jsonb_build_object('schemaVersion','portal.public-navigation.v1','countBasis','public_versions',
      'dimension',p_dimension,'kind',p_kind,'totals',v_totals,'parent',v_parent,'ancestors',v_ancestors,'nodes',v_nodes,
      'nextCursor',case when v_next is null then null else private.portal_cursor_encode_v1(jsonb_build_object(
        'v',1,'fp',p_fingerprint,'dimension',p_dimension,'kind',p_kind,'parent',p_parent_node_id,'node',v_next)) end);
    exit when octet_length(v_result::text)<=65536;
    if jsonb_array_length(v_nodes)<=1 then
      raise exception using errcode='54000',message='Portal navigation response exceeds its byte budget';
    end if;
    v_nodes:=v_nodes-(jsonb_array_length(v_nodes)-1);
    v_next:=v_nodes->(jsonb_array_length(v_nodes)-1)->>'nodeId';
  end loop;
  return v_result;
end;
$$;

ALTER FUNCTION "private"."portal_navigation_impl_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor_node_id" "text", "p_limit" integer, "p_fingerprint" "text") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."portal_navigation_impl_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor_node_id" "text", "p_limit" integer, "p_fingerprint" "text") FROM PUBLIC;

CREATE OR REPLACE FUNCTION "private"."catalog_portal_facets_empty_v2_impl"("p_kind" "text", "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "work_mem" TO '32MB'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
  with visible_versions as not materialized (
    select
      facet.dataset_kind,
      facet.id,
      facet.version,
      facet.facet_access_level,
      facet.facet_geography,
      facet.facet_reference_year,
      facet.facet_process_subtype,
      facet.facet_source
    from private.portal_catalog_facet_rows_v1 as facet
    where facet.facet_contract_version = 1 and facet.state_code in (100,200)
      and (p_kind = 'all' or facet.dataset_kind = p_kind)
  ), facts as not materialized (
    select visible_versions.dataset_kind,
      visible_versions.facet_access_level,
      visible_versions.facet_geography,
      visible_versions.facet_reference_year,
      case when visible_versions.dataset_kind = 'process' then
        visible_versions.facet_process_subtype
      else null::text end as facet_process_subtype,
      visible_versions.facet_source
    from visible_versions
  ), counts_raw as materialized (
    select case
        when grouping(facts.dataset_kind) = 0 then 'kind'
        when grouping(facts.facet_access_level) = 0 then 'accessLevel'
        when grouping(facts.facet_geography) = 0 then 'geography'
        when grouping(facts.facet_reference_year) = 0 then 'referenceYear'
        when grouping(facts.facet_process_subtype) = 0 then 'processSubtype'
        else 'source'
      end as group_id,
      case
        when grouping(facts.dataset_kind) = 0 then 1
        when grouping(facts.facet_access_level) = 0 then 2
        when grouping(facts.facet_geography) = 0 then 3
        when grouping(facts.facet_reference_year) = 0 then 4
        when grouping(facts.facet_process_subtype) = 0 then 5
        else 6
      end as group_order,
      case
        when grouping(facts.dataset_kind) = 0 then facts.dataset_kind
        when grouping(facts.facet_access_level) = 0 then
          facts.facet_access_level
        when grouping(facts.facet_geography) = 0 then facts.facet_geography
        when grouping(facts.facet_reference_year) = 0 then
          facts.facet_reference_year
        when grouping(facts.facet_process_subtype) = 0 then
          facts.facet_process_subtype
        else facts.facet_source
      end as value,
      pg_catalog.count(*) as value_count
    from facts
    group by grouping sets (
      (facts.dataset_kind),
      (facts.facet_access_level),
      (facts.facet_geography),
      (facts.facet_reference_year),
      (facts.facet_process_subtype),
      (facts.facet_source)
    )
  ), counts as materialized (
    select counts_raw.group_id,
      counts_raw.group_order,
      counts_raw.value,
      counts_raw.value as label,
      counts_raw.value_count
    from counts_raw
    where nullif(pg_catalog.btrim(counts_raw.value), '') is not null
      and pg_catalog.length(counts_raw.value) <= 128
      and pg_catalog.octet_length(counts_raw.value) <= 512
  ), ranked_counts as materialized (
    select counts.*,
      pg_catalog.row_number() over (
        partition by counts.group_id
        order by counts.value
      ) as value_rank
    from counts
  ), grouped as materialized (
    select ranked_counts.group_id,
      ranked_counts.group_order,
      pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'value', ranked_counts.value,
        'label', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'language', 'und', 'value', ranked_counts.label
          )
        ),
        'count', ranked_counts.value_count
      ) order by ranked_counts.value)
        filter (where ranked_counts.value_rank <= 100) as values_json,
      pg_catalog.bool_or(ranked_counts.value_rank > 100) as has_more
    from ranked_counts
    group by ranked_counts.group_id, ranked_counts.group_order
  ), groups as (
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', grouped.group_id,
      'label', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'language', 'en',
          'value', case grouped.group_id
            when 'kind' then 'Object type'
            when 'accessLevel' then 'Access level'
            when 'geography' then 'Geography'
            when 'referenceYear' then 'Reference year'
            when 'processSubtype' then 'Process subtype'
            else 'Source'
          end
        ),
        pg_catalog.jsonb_build_object(
          'language', 'zh-CN',
          'value', case grouped.group_id
            when 'kind' then '对象类型'
            when 'accessLevel' then '访问级别'
            when 'geography' then '地区'
            when 'referenceYear' then '参考年'
            when 'processSubtype' then '过程类型'
            else '数据源'
          end
        )
      ),
      'values', grouped.values_json,
      'hasMore', grouped.has_more
    ) order by grouped.group_order), '[]'::jsonb) as value
    from grouped
  )
  select pg_catalog.jsonb_build_object(
    'schemaVersion', 'portal.public-facets.v2',
    'kind', p_kind,
    'queryFingerprint', p_query_fingerprint,
    'groups', groups.value
  )
  from groups
$$;

ALTER FUNCTION "private"."catalog_portal_facets_empty_v2_impl"("p_kind" "text", "p_query_fingerprint" "text") OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."catalog_portal_facets_empty_v2_impl"("p_kind" "text", "p_query_fingerprint" "text") FROM PUBLIC;

reset role;
do $portal_empty_acl_end$
declare before_grant jsonb;
begin
  if pg_catalog.current_setting('portal_empty_cutover.create_added')::boolean then
    revoke create on schema private from portal_public_executor;
  end if;
  before_grant:=pg_catalog.current_setting('portal_empty_cutover.postgres_grant')::jsonb;
  if before_grant='null'::jsonb then
    revoke portal_public_executor from postgres;
  else
    execute pg_catalog.format('grant portal_public_executor to postgres with admin %s, inherit %s, set %s',
      before_grant->>'admin',before_grant->>'inherit',before_grant->>'set');
  end if;
end;
$portal_empty_acl_end$;
commit;
