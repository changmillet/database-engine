-- Database #869, phase B: fill, index and activate the native Flow CAS fact.
-- Phase A is already committed, so backfill/index work does not hold the short
-- ADD COLUMN ACCESS EXCLUSIVE lock. Existing readers remain usable until this
-- transaction atomically activates the new reader and manifest. Source writes
-- are fenced throughout backfill; all existing ACL/RLS/request budgets remain.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
select private.portal_display_assert_contract_v1();
do $display_flow_cas_role_guard$
begin
  if not coalesce((select rolsuper or rolbypassrls from pg_catalog.pg_roles
                   where rolname=current_user),false) then
    raise exception using errcode='55000',
      message='Display Flow CAS cutover requires an RLS-bypassing migration role';
  end if;
end;
$display_flow_cas_role_guard$;

-- Fence normal projection writers before changing their helper or derived fact.
-- Their established order is V1 then V2; SELECT readers remain admitted.
lock table private.display_catalog_search_rows_v1,
  private.display_catalog_search_rows_v2 in share row exclusive mode;

-- Keep the activation witness absent until this transaction creates it. This
-- also fences concurrent index DDL between preflight and backfill, while still
-- admitting SELECT readers. Preserve the writer's source-before-navigation order.
lock table private.display_navigation_versions_v1 in share row exclusive mode;

do $display_flow_cas_column_guard$
begin
  if not exists (
    select 1 from pg_catalog.pg_attribute
    where attrelid='private.display_navigation_versions_v1'::regclass
      and attname='cas_number' and not attisdropped
      and atttypid='pg_catalog.text'::regtype and atttypmod=-1
      and not attnotnull and not atthasdef
      and attgenerated='' and attidentity=''
  ) then
    raise exception using errcode='55000',
      message='Display Flow CAS cutover requires the prepared native text fact';
  end if;
end;
$display_flow_cas_column_guard$;

do $display_flow_cas_preflight$
begin
  -- This catalog row is also the snapshot-visible activation witness used by
  -- the reader. Its first creation must belong to the same transaction as the
  -- full backfill and native matcher; an earlier unrelated index cannot prove
  -- that older snapshots contain the derived facts.
  if pg_catalog.to_regclass('private.d807_portal_navigation_versions_flow_cas_v1_idx') is not null
     and pg_catalog.strpos(pg_catalog.pg_get_functiondef(
       'private.display_navigation_matched_versions_v1(text,text,jsonb)'::regprocedure
     ),'display-flow-cas-native-v1')=0 then
    raise exception using errcode='55000',
      message='Display Flow CAS cutover index exists before native activation';
  end if;
  if exists (
    select 1
    from (select id,version from private.display_catalog_search_rows_v1 where dataset_kind='flow') p
    full join (select id,version from private.display_navigation_versions_v1 where dataset_kind='flow') n
      using(id,version)
    where p.id is null or n.id is null
  ) then
    raise exception using errcode='55000',
      message='Display Flow CAS cutover projection coverage or facts drifted';
  end if;
  -- The qualified matcher marker also identifies activation if its index was
  -- subsequently lost. Reject active fact drift before any backfill; neither
  -- an index loss nor a retry may silently repair an authoritative live fact.
  if pg_catalog.to_regclass('private.d807_portal_navigation_versions_flow_cas_v1_idx') is not null
     or pg_catalog.strpos(pg_catalog.pg_get_functiondef(
       'private.display_navigation_matched_versions_v1(text,text,jsonb)'::regprocedure
     ),'display-flow-cas-native-v1')>0 then
    if exists (
    with expected as (
      select p.dataset_kind,p.id,p.version,case when p.dataset_kind='flow'
      and pg_catalog.jsonb_typeof(p.card -> 'casNumber')='string'
      and p.card ->> 'casNumber' ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
      and pg_catalog.length(p.card ->> 'casNumber') between 7 and 12
      then p.card ->> 'casNumber' end as cas_number
      from private.display_catalog_search_rows_v1 p
      where p.dataset_kind='flow'
    )
    select 1 from expected p
    full join (select * from private.display_navigation_versions_v1 where dataset_kind='flow') n
      using(dataset_kind,id,version)
    where p.id is null or n.id is null or n.cas_number is distinct from p.cas_number
  ) or exists (
    select 1 from private.display_navigation_versions_v1
    where dataset_kind<>'flow' and cas_number is not null
  ) then
      raise exception using errcode='55000',
        message='Display Flow CAS cutover projection coverage or facts drifted';
    end if;
  end if;
end;
$display_flow_cas_preflight$;

-- Source writes are fenced. Backfill therefore reads one committed source
-- generation and cannot overwrite a newer writer's CAS fact with stale data.
update private.display_navigation_versions_v1 n
set cas_number=case when p.dataset_kind='flow'
      and pg_catalog.jsonb_typeof(p.card -> 'casNumber')='string'
      and p.card ->> 'casNumber' ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
      and pg_catalog.length(p.card ->> 'casNumber') between 7 and 12
      then p.card ->> 'casNumber' end
from private.display_catalog_search_rows_v1 p
where (n.dataset_kind,n.id,n.version)=(p.dataset_kind,p.id,p.version)
  and n.cas_number is distinct from (case when p.dataset_kind='flow'
      and pg_catalog.jsonb_typeof(p.card -> 'casNumber')='string'
      and p.card ->> 'casNumber' ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
      and pg_catalog.length(p.card ->> 'casNumber') between 7 and 12
      then p.card ->> 'casNumber' end);

create index if not exists d807_portal_navigation_versions_flow_cas_v1_idx
on private.display_navigation_versions_v1 (dataset_kind,cas_number,id,version)
where dataset_kind='flow' and cas_number is not null;

do $display_flow_cas_cutover_guard$
begin
  if exists (
    with expected as (
      select p.dataset_kind,p.id,p.version,case when p.dataset_kind='flow'
      and pg_catalog.jsonb_typeof(p.card -> 'casNumber')='string'
      and p.card ->> 'casNumber' ~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$'
      and pg_catalog.length(p.card ->> 'casNumber') between 7 and 12
      then p.card ->> 'casNumber' end as cas_number
      from private.display_catalog_search_rows_v1 p
      where p.dataset_kind='flow'
    )
    select 1 from expected p
    full join (select * from private.display_navigation_versions_v1 where dataset_kind='flow') n
      using(dataset_kind,id,version)
    where p.id is null or n.id is null or n.cas_number is distinct from p.cas_number
  ) or exists (
    select 1 from private.display_navigation_versions_v1
    where dataset_kind<>'flow' and cas_number is not null
  ) then
    raise exception using errcode='55000',
      message='Display Flow CAS cutover projection coverage or facts drifted';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_index i
    join pg_catalog.pg_class c on c.oid=i.indexrelid
    join pg_catalog.pg_am am on am.oid=c.relam
    where i.indexrelid=pg_catalog.to_regclass('private.d807_portal_navigation_versions_flow_cas_v1_idx')
      and i.indrelid='private.display_navigation_versions_v1'::regclass
      and i.indisvalid and i.indisready and i.indislive and not i.indisunique
      and i.indnkeyatts=4 and i.indnatts=4 and am.amname='btree'
      and pg_catalog.pg_get_indexdef(i.indexrelid,1,true)='dataset_kind'
      and pg_catalog.pg_get_indexdef(i.indexrelid,2,true)='cas_number'
      and pg_catalog.pg_get_indexdef(i.indexrelid,3,true)='id'
      and pg_catalog.pg_get_indexdef(i.indexrelid,4,true)='version'
      and pg_catalog.regexp_replace(pg_catalog.pg_get_expr(i.indpred,i.indrelid),'[[:space:]]','','g')
        =$$((dataset_kind='flow'::text)AND(cas_numberISNOTNULL))$$
  ) then
    raise exception using errcode='55000',
      message='Display Flow CAS cutover requires the qualified native CAS index';
  end if;
end;
$display_flow_cas_cutover_guard$;

CREATE OR REPLACE FUNCTION "private"."display_navigation_matched_versions_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb") RETURNS TABLE("dataset_kind" "text", "id" "uuid", "version" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    SET "plan_cache_mode" TO 'force_custom_plan'
    AS $_$
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
    -- Native CAS text equality stays indexable under the unchanged forced RLS.
    -- Its guarded fact is synchronized by the existing navigation writer.
    -- Preserve Process lexical candidates and every original navigation filter.
    -- display-flow-cas-native-v1
    if private.display_catalog_summary_valid_cas_v1(p_query) then
      -- These are ordinary catalog SELECTs in this STABLE call's data snapshot,
      -- not a current-cache to_regclass readiness test. A call begun before B
      -- cannot see B's index catalog rows or backfilled facts, even when a late
      -- inner call resolves this new function body. Keep its original reader.
      if not exists (
        select 1
        from pg_catalog.pg_class idx
        join pg_catalog.pg_namespace ns on ns.oid=idx.relnamespace
        join pg_catalog.pg_index i on i.indexrelid=idx.oid
        where ns.nspname='private'
          and idx.relname='d807_portal_navigation_versions_flow_cas_v1_idx'
          and i.indrelid='private.display_navigation_versions_v1'::regclass
          and i.indisvalid and i.indisready and i.indislive
      ) then
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
    return query
    with cas_keys as materialized (
      select c.dataset_kind,c.id,c.version
      from private.display_catalog_facet_candidate_rows_v2(
        'process',p_query,v_exact,v_pattern
      ) c
      where p_kind in ('all','process')
      union all
      select n.dataset_kind,n.id,n.version
      from private.display_navigation_versions_v1 n
      where p_kind in ('all','flow') and n.dataset_kind='flow'
        and n.cas_number=p_query
    )
    select v.dataset_kind,v.id,v.version
    from cas_keys c
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
$_$;

update private.portal_display_contract_manifest
set identity=private.portal_display_contract_identity_v1() where singleton;
select private.portal_display_assert_contract_v1();
notify pgrst, 'reload schema';
commit;
