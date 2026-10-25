-- Database #864: preserve exact visible versions while avoiding wide lexical
-- materialization and redundant existence checks in Facets/Navigation.
-- Existing signatures, owners, ACLs, RLS, writers and request budgets are kept.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';
select private.portal_display_assert_contract_v1();

-- Run as postgres in the migration transaction before replacing the readers.
-- This reads all display projections independent of request/brand RLS. It does
-- not repair drift, write tables, or change writers, triggers, roles or ACLs.
do $display_facets_cutover_guard$
declare
  v_drift boolean;
begin
  if not coalesce((select rolsuper or rolbypassrls from pg_catalog.pg_roles
                   where rolname=current_user),false) then
    raise exception using errcode='55000',
      message='Display facets cutover requires an RLS-bypassing migration role';
  end if;
  with current_facts as materialized (
    select p.dataset_kind, p.id, p.version, p.state_code, p.modified_at,
      p.card ->> 'accessLevel' as access_level,
      pg_catalog.lower(pg_catalog.btrim(p.card #>> '{geography,code}'))
        as geography_code,
      array(
        select distinct pg_catalog.lower(pg_catalog.btrim(entry ->> 'code'))
        from pg_catalog.jsonb_array_elements(
          coalesce(p.card -> 'classifications', '[]'::jsonb)
        ) as entry
        where nullif(pg_catalog.btrim(entry ->> 'code'), '') is not null
        order by pg_catalog.lower(pg_catalog.btrim(entry ->> 'code'))
      ) as classification_codes,
      (p.card ->> 'referenceYear')::integer as reference_year,
      -- Facet output is card text, not navigation integer::text. Keep the
      -- independent text comparison so padding/format differences between the
      -- current card and facet projection cannot be hidden by an integer cast.
      pg_catalog.btrim(p.card ->> 'referenceYear') as facet_reference_year,
      pg_catalog.lower(pg_catalog.btrim(p.card ->> 'processSubtype'))
        as process_subtype,
      pg_catalog.lower(pg_catalog.btrim(p.card ->> 'source')) as source
    from private.display_catalog_search_current_v2 as p
  )
  select exists (
    select 1
    from current_facts as c
    full join private.display_navigation_versions_v1 as n
      using (dataset_kind, id, version)
    full join private.display_catalog_facet_rows_v1 as f
      using (dataset_kind, id, version)
    full join private.display_catalog_search_rows_v1 as original
      using (dataset_kind, id, version)
    where c.id is null or n.id is null or f.id is null or original.id is null
      or f.facet_contract_version is distinct from 1
      or (n.access_level, n.geography_code, n.reference_year,
          n.process_subtype, n.source)
        is distinct from
         (c.access_level, c.geography_code, c.reference_year,
          c.process_subtype, c.source)
      or array(
        select code
        from pg_catalog.unnest(n.classification_codes) as item(code)
        order by code
      ) is distinct from c.classification_codes
      or (f.state_code, f.modified_at, f.facet_access_level,
          f.facet_geography, f.facet_reference_year,
          f.facet_process_subtype, f.facet_source)
        is distinct from
         (c.state_code, c.modified_at, c.access_level,
          c.geography_code, c.facet_reference_year,
          case when c.dataset_kind = 'process' then c.process_subtype end,
          c.source)
  ) into v_drift;

  if v_drift then
    raise exception using errcode = '55000',
      message = 'Display facets cutover projection coverage or facts drifted';
  end if;
exception
  when data_exception then
    -- Malformed stored card facts (for example a noninteger reference year
    -- or nonarray classifications) are contract drift, never a repair path.
    raise exception using errcode = '55000',
      message = 'Display facets cutover projection coverage or facts drifted';
end;
$display_facets_cutover_guard$;


CREATE OR REPLACE FUNCTION "private"."display_navigation_matched_versions_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") RETURNS TABLE("dataset_kind" "text", "id" "uuid", "version" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    SET "plan_cache_mode" TO 'force_custom_plan'
    AS $$
declare
  v_exact uuid;
  v_pattern text;
begin
  if p_query='' then
    -- Empty/query-free navigation never detoasts public cards or raw source JSON.
    return query select v.dataset_kind,v.id,v.version
    from private.display_navigation_versions_v1 v
    where (p_kind='all' or v.dataset_kind=p_kind) and
      (not (p_filters ? 'accessLevel') or v.access_level=p_filters->>'accessLevel')
      and (not (p_filters ? 'geography') or v.geography_code=p_filters->>'geography')
      and (not (p_filters ? 'classification') or v.classification_codes @> array[p_filters->>'classification'])
      and (not (p_filters ? 'referenceYearFrom') or v.reference_year >= (p_filters->>'referenceYearFrom')::integer)
      and (not (p_filters ? 'referenceYearTo') or v.reference_year <= (p_filters->>'referenceYearTo')::integer)
      and (not (p_filters ? 'processSubtype') or v.process_subtype=p_filters->>'processSubtype')
      and (not (p_filters ? 'source') or v.source=p_filters->>'source')
      and (
        not (p_filters ? 'classificationNodeId')
        or (v.dataset_kind,v.id,v.version) in (
          select m.dataset_kind,m.id,m.version
          from private.display_navigation_membership_v1 m
          where m.dimension='classification'
            and m.node_id=p_filters->>'classificationNodeId'
            and (p_kind='all' or m.dataset_kind=p_kind)
            and (coalesce(p_filters->>'classificationScope','subtree')<>'direct' or m.direct)
        )
      ) and (
        not (p_filters ? 'geographyNodeId')
        or (v.dataset_kind,v.id,v.version) in (
          select m.dataset_kind,m.id,m.version
          from private.display_navigation_membership_v1 m
          where m.dimension='geography'
            and m.node_id=p_filters->>'geographyNodeId'
            and (p_kind='all' or m.dataset_kind=p_kind)
            and (coalesce(p_filters->>'geographyScope','subtree')<>'direct' or m.direct)
        )
      )
;
  else
    if p_query ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then v_exact:=p_query::uuid; end if;
    v_pattern := '%' || replace(replace(replace(p_query,chr(92),chr(92)||chr(92)),'%',chr(92)||'%'),'_',chr(92)||'_') || '%';
    -- Keep the established selective CAS plan; expanding it into the broad
    -- key union is not qualified at representative volume.
    if private.display_catalog_summary_valid_cas_v1(p_query) then
    return query select v.dataset_kind,v.id,v.version
    from private.display_catalog_facet_candidate_rows_v2(p_kind,p_query,v_exact,v_pattern) c
    join private.display_navigation_versions_v1 v
      on (v.dataset_kind,v.id,v.version)=(c.dataset_kind,c.id,c.version)
    where
      (not (p_filters ? 'accessLevel') or v.access_level=p_filters->>'accessLevel')
      and (not (p_filters ? 'geography') or v.geography_code=p_filters->>'geography')
      and (not (p_filters ? 'classification') or v.classification_codes @> array[p_filters->>'classification'])
      and (not (p_filters ? 'referenceYearFrom') or v.reference_year >= (p_filters->>'referenceYearFrom')::integer)
      and (not (p_filters ? 'referenceYearTo') or v.reference_year <= (p_filters->>'referenceYearTo')::integer)
      and (not (p_filters ? 'processSubtype') or v.process_subtype=p_filters->>'processSubtype')
      and (not (p_filters ? 'source') or v.source=p_filters->>'source')
      and (
        not (p_filters ? 'classificationNodeId')
        or (v.dataset_kind,v.id,v.version) in (
          select m.dataset_kind,m.id,m.version
          from private.display_navigation_membership_v1 m
          where m.dimension='classification'
            and m.node_id=p_filters->>'classificationNodeId'
            and (p_kind='all' or m.dataset_kind=p_kind)
            and (coalesce(p_filters->>'classificationScope','subtree')<>'direct' or m.direct)
        )
      ) and (
        not (p_filters ? 'geographyNodeId')
        or (v.dataset_kind,v.id,v.version) in (
          select m.dataset_kind,m.id,m.version
          from private.display_navigation_membership_v1 m
          where m.dimension='geography'
            and m.node_id=p_filters->>'geographyNodeId'
            and (p_kind='all' or m.dataset_kind=p_kind)
            and (coalesce(p_filters->>'geographyScope','subtree')<>'direct' or m.direct)
        )
      )
;
      return;
    end if;

    -- Pattern helpers and UUID lookup already read the authoritative current
    -- projection under the same RLS. Their UNION has one row per exact key.
    -- With empty filters the guarded complete navigation projection adds no
    -- predicate, so the planner may remove this unique-key LEFT JOIN.
    return query
    with lexical_keys as materialized (
      select 'process'::text dataset_kind,p.id,p.version
      from private.display_catalog_process_pattern_versions_v1(v_pattern) p
      where p_kind in ('all','process')
      union
      select 'flow'::text,p.id,p.version
      from private.display_catalog_flow_pattern_versions_v1(v_pattern) p
      where p_kind in ('all','flow')
      union
      select p.dataset_kind,p.id,p.version
      from private.display_catalog_search_current_v2 p
      where (p_kind='all' or p.dataset_kind=p_kind) and p.id=v_exact
    )
    select c.dataset_kind,c.id,c.version
    from lexical_keys c left join private.display_navigation_versions_v1 v
      on (v.dataset_kind,v.id,v.version)=(c.dataset_kind,c.id,c.version)
    where (p_filters='{}'::jsonb or v.id is not null) and
      (not (p_filters ? 'accessLevel') or v.access_level=p_filters->>'accessLevel')
      and (not (p_filters ? 'geography') or v.geography_code=p_filters->>'geography')
      and (not (p_filters ? 'classification') or v.classification_codes @> array[p_filters->>'classification'])
      and (not (p_filters ? 'referenceYearFrom') or v.reference_year >= (p_filters->>'referenceYearFrom')::integer)
      and (not (p_filters ? 'referenceYearTo') or v.reference_year <= (p_filters->>'referenceYearTo')::integer)
      and (not (p_filters ? 'processSubtype') or v.process_subtype=p_filters->>'processSubtype')
      and (not (p_filters ? 'source') or v.source=p_filters->>'source')
      and (
        not (p_filters ? 'classificationNodeId')
        or (v.dataset_kind,v.id,v.version) in (
          select m.dataset_kind,m.id,m.version
          from private.display_navigation_membership_v1 m
          where m.dimension='classification'
            and m.node_id=p_filters->>'classificationNodeId'
            and (p_kind='all' or m.dataset_kind=p_kind)
            and (coalesce(p_filters->>'classificationScope','subtree')<>'direct' or m.direct)
        )
      ) and (
        not (p_filters ? 'geographyNodeId')
        or (v.dataset_kind,v.id,v.version) in (
          select m.dataset_kind,m.id,m.version
          from private.display_navigation_membership_v1 m
          where m.dimension='geography'
            and m.node_id=p_filters->>'geographyNodeId'
            and (p_kind='all' or m.dataset_kind=p_kind)
            and (coalesce(p_filters->>'geographyScope','subtree')<>'direct' or m.direct)
        )
      )
;
  end if;
end;
$$;

CREATE OR REPLACE FUNCTION "private"."display_catalog_facets_v3_impl"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text", "p_filters" "jsonb", "p_query_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "plan_cache_mode" TO 'force_custom_plan'
    SET "row_security" TO 'on'
    AS $$
begin
  -- Canonical narrow facts preserve all six normalized values/labels.
    return (
with matched as materialized (
    select * from private.display_navigation_matched_versions_v1(p_kind,p_query,p_filters)
  ), visible_versions as materialized (
    select
      facet.dataset_kind,
      facet.id,
      facet.version,
      facet.facet_access_level,
      facet.facet_geography,
      facet.facet_reference_year,
      facet.facet_process_subtype,
      facet.facet_source
    from private.display_catalog_facet_rows_v1 as facet
    where facet.facet_contract_version = 1 and true
      and (p_kind = 'all' or facet.dataset_kind = p_kind)
      and (facet.dataset_kind,facet.id,facet.version) in (select dataset_kind,id,version from matched)
  ), facts as materialized (
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
    );
end;
$$;

CREATE OR REPLACE FUNCTION "private"."display_navigation_impl_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_dimension" "text", "p_parent_node_id" "text", "p_cursor_node_id" "text", "p_limit" integer, "p_fingerprint" "text") RETURNS "jsonb"
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
  perform private.display_assert_navigation_contract_v1();
  if p_parent_node_id is not null and not exists (
    select 1 from private.display_read_navigation_node_v1 n
    where n.node_id=p_parent_node_id and n.dimension=p_dimension
      and (n.source_file is not null or n.node_id in ('class:isic','class:cpc','class:elementary','geo:unmapped')
        or exists(select 1 from private.display_navigation_membership_v1 m where m.node_id=n.node_id))
  ) then raise exception using errcode='22023',message='invalid portal request'; end if;
  if p_cursor_node_id is not null then
    select n.code into v_after_code from private.display_read_navigation_node_v1 n
    where n.node_id=p_cursor_node_id and n.dimension=p_dimension
      and n.parent_node_id is not distinct from p_parent_node_id;
    if not found then raise exception using errcode='22023',message='invalid portal request'; end if;
  end if;

  with matched as materialized (
    select * from private.display_navigation_matched_versions_v1('all',p_query,p_filters)
  ), children as materialized (
    select n.* from private.display_read_navigation_node_v1 n
    where n.dimension=p_dimension and n.parent_node_id is not distinct from p_parent_node_id
      and (n.source_file is not null or n.node_id in ('class:isic','class:cpc','class:elementary','geo:unmapped') or exists (
        select 1 from private.display_navigation_membership_v1 m
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
    select n.* from private.display_read_navigation_node_v1 n where n.node_id=p_parent_node_id
  ), counted as materialized (
    select m.node_id,count(*) as count,count(*) filter(where m.direct) as direct_count
    from private.display_navigation_membership_v1 m
    where m.dimension=p_dimension and (p_kind='all' or m.dataset_kind=p_kind)
      and ((p_query='' and p_filters='{}'::jsonb)
        or (m.dataset_kind,m.id,m.version) in (select dataset_kind,id,version from matched))
      and m.node_id = any(array(select n.node_id from targets n))
    group by m.node_id
  ), decorated as materialized (
    select n.node_id,n.code,jsonb_build_object(
      'nodeId',n.node_id,'parentNodeId',n.parent_node_id,'code',n.code,'taxonomy',n.taxonomy,
      'count',coalesce(c.count,0),'directCount',coalesce(c.direct_count,0),
      'hasChildren',exists(select 1 from private.display_read_navigation_node_v1 child where child.parent_node_id=n.node_id
        and (child.source_file is not null or exists(select 1 from private.display_navigation_membership_v1 m where m.node_id=child.node_id)))
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
       from private.display_navigation_versions_v1)
     else (select jsonb_build_object('process',count(*) filter(where dataset_kind='process'),'flow',count(*) filter(where dataset_kind='flow')) from matched) end)
  into v_nodes,v_next,v_parent,v_totals;

  with recursive ancestors as (
    select n.node_id,n.parent_node_id,n.code,n.taxonomy,1 as depth
    from private.display_read_navigation_node_v1 n
    where n.node_id=(select p.parent_node_id from private.display_read_navigation_node_v1 p where p.node_id=p_parent_node_id)
    union all
    select n.node_id,n.parent_node_id,n.code,n.taxonomy,a.depth+1
    from ancestors a join private.display_read_navigation_node_v1 n on n.node_id=a.parent_node_id
    where a.depth<32
  ) select coalesce(jsonb_agg(jsonb_build_object('nodeId',node_id,'parentNodeId',parent_node_id,'code',code,'taxonomy',taxonomy) order by depth desc),'[]'::jsonb)
    into v_ancestors from ancestors;

  loop
    v_result:=jsonb_build_object('schemaVersion','portal.public-navigation.v1','countBasis','public_versions',
      'dimension',p_dimension,'kind',p_kind,'totals',v_totals,'parent',v_parent,'ancestors',v_ancestors,'nodes',v_nodes,
      'nextCursor',case when v_next is null then null else private.display_cursor_encode_v1(jsonb_build_object(
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

CREATE OR REPLACE FUNCTION "private"."portal_display_brand_facets_v1"("p_page" "jsonb", "p_kind" "text", "p_query" "text", "p_filters" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
 -- Wide empty matching adds no filter after the symmetric coverage guard.
 -- Retain the original selective Process path, where direct V1 scanning regresses.
 -- Every existing projection writer maintains these exact version sets.
 select jsonb_set(p_page,'{groups}',(p_page->'groups') || jsonb_build_array(jsonb_build_object(
  'id','brand','label',jsonb_build_array(jsonb_build_object('language','en','value','Database brand')),
  'hasMore',false,'values',case when lower(btrim(coalesce(p_query,'')))='' and private.display_normalize_filters_v1(p_filters)='{}'::jsonb
   and lower(btrim(p_kind)) <> 'process'
 then coalesce((select jsonb_agg(jsonb_build_object(
   'value',brand,'label',jsonb_build_array(jsonb_build_object('language','en','value',private.portal_brand_v1(brand)->>'name')),
   'count',total) order by brand)
   from (select p.brand,count(*) as total
    from private.display_catalog_search_rows_v1 p
    where lower(btrim(p_kind))='all' or p.dataset_kind=lower(btrim(p_kind))
    group by p.brand) counted),'[]'::jsonb)
 else coalesce((select jsonb_agg(jsonb_build_object(
   'value',brand,'label',jsonb_build_array(jsonb_build_object('language','en','value',private.portal_brand_v1(brand)->>'name')),
   'count',total) order by brand)
   from (select p.brand,count(*) as total
    from private.display_navigation_matched_versions_v1(lower(btrim(p_kind)),lower(btrim(coalesce(p_query,''))),private.display_normalize_filters_v1(p_filters)) k
    join private.display_catalog_search_rows_v1 p using(dataset_kind,id,version)
    group by p.brand) counted),'[]'::jsonb) end)))
$$;

update private.portal_display_contract_manifest
set identity = private.portal_display_contract_identity_v1() where singleton;
select private.portal_display_assert_contract_v1();
notify pgrst, 'reload schema';
commit;
