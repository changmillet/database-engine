-- Database #799: exact-version, reversible display configuration.
begin;
create table private.dataset_display_settings (
  dataset_kind text not null check (dataset_kind in ('lifecyclemodel','process','flow','flowproperty','unitgroup','source','contact')),
  dataset_id uuid not null,
  dataset_version character(9) not null check (dataset_version ~ '^\d{2}\.\d{2}\.\d{3}$'),
  is_visible boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (dataset_kind, dataset_id, dataset_version)
);
alter table private.dataset_display_settings owner to postgres;
alter table private.dataset_display_settings enable row level security;
revoke all on private.dataset_display_settings from public, anon, authenticated, service_role, api_internal_executor;
create index dataset_display_settings_visible_idx on private.dataset_display_settings(dataset_kind,dataset_id,dataset_version) where is_visible;
comment on table private.dataset_display_settings is 'Exact-version list visibility only. Missing configuration is hidden; no actor or history is stored. Does not confer raw, export, Portal, calculation or numerical publication access.';

-- Preserve previously selected exact Process versions, without retaining actor identity.
insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible,updated_at)
select 'process',process_id,process_version,true,published_at from private.open_data_process_publications;

-- Private owner-only source projection: no source JSON, owner or team leaves this boundary.
create view private.dataset_display_catalog as
select 'lifecyclemodel'::text as dataset_kind,id as dataset_id,version::text as dataset_version,json #> '{lifeCycleModelDataSet,lifeCycleModelInformation,dataSetInformation,name}' as name,state_code from public.lifecyclemodels
union all
select 'process'::text as dataset_kind,id as dataset_id,version::text as dataset_version,json #> '{processDataSet,processInformation,dataSetInformation,name}' as name,state_code from public.processes
union all
select 'flow'::text as dataset_kind,id as dataset_id,version::text as dataset_version,json #> '{flowDataSet,flowInformation,dataSetInformation,name}' as name,state_code from public.flows
union all
select 'flowproperty'::text as dataset_kind,id as dataset_id,version::text as dataset_version,json #> '{flowPropertyDataSet,flowPropertiesInformation,dataSetInformation,common:name}' as name,state_code from public.flowproperties
union all
select 'unitgroup'::text as dataset_kind,id as dataset_id,version::text as dataset_version,json #> '{unitGroupDataSet,unitGroupInformation,dataSetInformation,common:name}' as name,state_code from public.unitgroups
union all
select 'source'::text as dataset_kind,id as dataset_id,version::text as dataset_version,coalesce(json #> '{sourceDataSet,sourceInformation,dataSetInformation,common:shortName}', json #> '{sourceDataSet,sourceInformation,dataSetInformation,sourceCitation}') as name,state_code from public.sources
union all
select 'contact'::text as dataset_kind,id as dataset_id,version::text as dataset_version,coalesce(json #> '{contactDataSet,contactInformation,dataSetInformation,common:name}', json #> '{contactDataSet,contactInformation,dataSetInformation,common:shortName}') as name,state_code from public.contacts;
alter view private.dataset_display_catalog owner to postgres;
revoke all on private.dataset_display_catalog from public, anon, authenticated, service_role, api_internal_executor;

create function private.dataset_display_require_manager() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception using errcode='28000',message='authentication required'; end if;
  if not exists (select 1 from private.roles where user_id=auth.uid()
    and team_id='00000000-0000-0000-0000-000000000000'::uuid and role::text='data_product_manager') then
    raise exception using errcode='42501',message='data_product_manager role required';
  end if;
end; $$;
alter function private.dataset_display_require_manager() owner to postgres;
revoke all on function private.dataset_display_require_manager() from public,anon,authenticated,service_role,api_internal_executor;

create function private.dataset_display_list(p_kind text,p_visibility text,p_query text,p_page_size integer,p_page integer,p_candidates boolean)
returns jsonb language plpgsql stable security definer set search_path = '' set statement_timeout='15s' as $$
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
alter function private.dataset_display_list(text,text,text,integer,integer,boolean) owner to postgres;
revoke all on function private.dataset_display_list(text,text,text,integer,integer,boolean) from public,anon,authenticated,service_role,api_internal_executor;

create function api.list_dataset_display_candidates(p_dataset_kind text default 'all',p_visibility text default 'all',p_query text default '',p_page_size integer default 20,p_page integer default 1)
returns jsonb language sql stable security definer set search_path='' set statement_timeout='15s' as $$
  select private.dataset_display_list(p_dataset_kind,p_visibility,p_query,p_page_size,p_page,true);
$$;
create function api.list_displayed_datasets(p_dataset_kind text default 'all',p_query text default '',p_page_size integer default 20,p_page integer default 1)
returns jsonb language sql stable security definer set search_path='' set statement_timeout='15s' as $$
  select private.dataset_display_list(p_dataset_kind,'visible',p_query,p_page_size,p_page,false);
$$;

create function api.cmd_dataset_display_set_batch(p_items jsonb,p_is_visible boolean)
returns jsonb language plpgsql security definer set search_path='' set statement_timeout='15s' as $$
declare v_item record; v_table text; v_exists boolean; v_current boolean; v_requested integer:=0; v_changed integer:=0;
begin
  perform private.dataset_display_require_manager();
  if p_is_visible is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception using errcode='22023',message='items must be an array and isVisible a boolean';
  end if;
  if jsonb_array_length(p_items) not between 1 and 100 then
    raise exception using errcode='22023',message='items must contain between 1 and 100 exact dataset versions';
  end if;
  if exists(select 1 from jsonb_array_elements(p_items) t(v) where jsonb_typeof(v) is distinct from 'object'
    or jsonb_typeof(v->'datasetKind') is distinct from 'string' or (v->>'datasetKind') not in ('lifecyclemodel','process','flow','flowproperty','unitgroup','source','contact')
    or jsonb_typeof(v->'id') is distinct from 'string' or not ((v->>'id')~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    or jsonb_typeof(v->'version') is distinct from 'string' or not ((v->>'version')~'^\d{2}\.\d{2}\.\d{3}$')
    or v - array['datasetKind','id','version']::text[] <> '{}'::jsonb) then
    raise exception using errcode='22023',message='each item must contain only a supported datasetKind, valid id and version';
  end if;
  -- Lock each exact source in the same global order. No state/owner/team predicate.
  -- FOR UPDATE serializes overlapping commands and source deletion/identity changes.
  for v_item in select distinct v->>'datasetKind' as kind,(v->>'id')::uuid as id,(v->>'version')::character(9) as version
    from jsonb_array_elements(p_items) t(v) order by 1,2,3 loop
    v_table:=case v_item.kind when 'lifecyclemodel' then 'lifecyclemodels' when 'process' then 'processes' when 'flow' then 'flows'
      when 'flowproperty' then 'flowproperties' when 'unitgroup' then 'unitgroups' when 'source' then 'sources' when 'contact' then 'contacts' end;
    v_exists:=false;
    execute format('select true from public.%I where id=$1 and version=$2 for update',v_table) into v_exists using v_item.id,v_item.version;
    if v_exists is distinct from true then raise exception using errcode='22023',message='all requested dataset versions must exist'; end if;
    v_requested:=v_requested+1;
    select is_visible into v_current from private.dataset_display_settings
      where dataset_kind=v_item.kind and dataset_id=v_item.id and dataset_version=v_item.version;
    if coalesce(v_current,false) is distinct from p_is_visible then
      insert into private.dataset_display_settings(dataset_kind,dataset_id,dataset_version,is_visible)
      values(v_item.kind,v_item.id,v_item.version,p_is_visible)
      on conflict(dataset_kind,dataset_id,dataset_version) do update set is_visible=excluded.is_visible,updated_at=now();
      v_changed:=v_changed+1;
    end if;
  end loop;
  return jsonb_build_object('ok',true,'data',jsonb_build_object('inputCount',jsonb_array_length(p_items),'requestedCount',v_requested,'changedCount',v_changed,'unchangedCount',v_requested-v_changed,'isVisible',p_is_visible));
end; $$;

-- Polymorphic source lifetime: no dangling configuration after deletion or identity replacement.
create function private.dataset_display_source_cleanup() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if TG_OP='DELETE' or new.id is distinct from old.id or new.version is distinct from old.version then
    delete from private.dataset_display_settings where dataset_kind=TG_ARGV[0] and dataset_id=old.id and dataset_version=old.version;
  end if;
  return null;
end; $$;
alter function private.dataset_display_source_cleanup() owner to postgres;
revoke all on function private.dataset_display_source_cleanup() from public,anon,authenticated,service_role,api_internal_executor;
create trigger dataset_display_source_cleanup after delete or update of id,version on public.lifecyclemodels for each row execute function private.dataset_display_source_cleanup('lifecyclemodel');
create trigger dataset_display_source_cleanup after delete or update of id,version on public.processes for each row execute function private.dataset_display_source_cleanup('process');
create trigger dataset_display_source_cleanup after delete or update of id,version on public.flows for each row execute function private.dataset_display_source_cleanup('flow');
create trigger dataset_display_source_cleanup after delete or update of id,version on public.flowproperties for each row execute function private.dataset_display_source_cleanup('flowproperty');
create trigger dataset_display_source_cleanup after delete or update of id,version on public.unitgroups for each row execute function private.dataset_display_source_cleanup('unitgroup');
create trigger dataset_display_source_cleanup after delete or update of id,version on public.sources for each row execute function private.dataset_display_source_cleanup('source');
create trigger dataset_display_source_cleanup after delete or update of id,version on public.contacts for each row execute function private.dataset_display_source_cleanup('contact');
alter function api.list_dataset_display_candidates(text,text,text,integer,integer) owner to postgres;
revoke all on function api.list_dataset_display_candidates(text,text,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function api.list_dataset_display_candidates(text,text,text,integer,integer) to authenticated,api_internal_executor;
insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) values('api.list_dataset_display_candidates(text, text, text, integer, integer)','NX-CORE-02',false,true,false);
alter function api.list_displayed_datasets(text,text,integer,integer) owner to postgres;
revoke all on function api.list_displayed_datasets(text,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function api.list_displayed_datasets(text,text,integer,integer) to authenticated,api_internal_executor;
insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) values('api.list_displayed_datasets(text, text, integer, integer)','NX-CORE-02',false,true,false);
alter function api.cmd_dataset_display_set_batch(jsonb,boolean) owner to postgres;
revoke all on function api.cmd_dataset_display_set_batch(jsonb,boolean) from public,anon,authenticated,service_role;
grant execute on function api.cmd_dataset_display_set_batch(jsonb,boolean) to authenticated,api_internal_executor;
insert into private.api_capability_grants(routine_identity,capability_id,allow_anon,allow_authenticated,allow_service_role) values('api.cmd_dataset_display_set_batch(jsonb, boolean)','CLI-RPC-01',false,true,false);

create or replace function api.search_open_data_catalog(
  p_dataset_kind text,
  p_search_mode text default 'list',
  p_query_text text default '',
  p_query_terms text[] default null,
  p_filter_condition jsonb default '{}'::jsonb,
  p_source_filter text default 'all',
  p_publication_filter text default 'all',
  p_page_size integer default 10,
  p_page_current integer default 1,
  p_sort_by text default 'modified_at',
  p_sort_direction text default 'desc'
)
returns table (
  id uuid,
  "json" jsonb,
  version character(9),
  modified_at timestamptz,
  team_id uuid,
  model_id uuid,
  model_version character(9),
  is_published boolean,
  total_count bigint
)
language plpgsql
security definer
set search_path to api, private, public, util, extensions, pg_temp
set statement_timeout to '60s'
as $_$
declare
  v_kind text := lower(btrim(coalesce(p_dataset_kind, '')));
  v_mode text := lower(btrim(coalesce(p_search_mode, 'list')));
  v_source_filter text := lower(btrim(coalesce(p_source_filter, 'all')));
  v_publication_filter text := lower(btrim(coalesce(p_publication_filter, 'all')));
  v_table regclass;
  v_model_id_expression text := 'null::uuid';
  v_model_version_expression text := 'null::character(9)';
  v_match_clause text;
  v_score_expression text := '0::double precision';
  v_order_clause text;
  v_sort_by text := lower(btrim(coalesce(p_sort_by, 'modified_at')));
  v_sort_direction text := lower(btrim(coalesce(p_sort_direction, 'desc')));
  v_page_size integer := least(greatest(coalesce(p_page_size, 10), 1), 100);
  v_page_current integer := greatest(coalesce(p_page_current, 1), 1);
  v_filter jsonb := coalesce(p_filter_condition, '{}'::jsonb);
  v_terms text[];
  v_uuid_pattern text;
  v_sql text;
begin
  v_table := case v_kind
    when 'process' then 'public.processes'::regclass
    when 'flow' then 'public.flows'::regclass
    when 'lifecyclemodel' then 'public.lifecyclemodels'::regclass
    when 'contact' then 'public.contacts'::regclass
    when 'source' then 'public.sources'::regclass
    when 'unitgroup' then 'public.unitgroups'::regclass
    when 'flowproperty' then 'public.flowproperties'::regclass
    else null
  end;
  if v_table is null then
    raise exception using errcode = '22023', message = 'unsupported p_dataset_kind';
  end if;
  if v_mode not in ('list', 'lexical', 'uuid') then
    raise exception using errcode = '22023', message = 'p_search_mode must be list, lexical, or uuid';
  end if;
  if v_source_filter not in ('all', 'literature', 'enterprise') then
    raise exception using errcode = '22023', message = 'p_source_filter must be all, literature, or enterprise';
  end if;
  if v_publication_filter not in ('all', 'published', 'unpublished') then
    raise exception using errcode = '22023', message = 'p_publication_filter must be all, published, or unpublished';
  end if;
  if v_kind <> 'process' and v_publication_filter <> 'all' then
    raise exception using errcode = '22023', message = 'publication filter is supported only for Process data';
  end if;
  if v_sort_by not in ('version', 'created_at', 'modified_at') then
    v_sort_by := 'modified_at';
  end if;
  if v_sort_direction not in ('asc', 'desc') then
    v_sort_direction := 'desc';
  end if;

  if v_kind = 'process' then
    v_model_id_expression := 'd.model_id';
    v_model_version_expression := 'd.model_version';
  end if;

  if v_mode = 'lexical' then
    v_terms := private.pgroonga_escape_query_terms(p_query_terms);
    if cardinality(v_terms) = 0 then
      v_terms := private.pgroonga_escape_query_terms(array[p_query_text]);
    end if;
    if cardinality(v_terms) = 0 then
      raise exception using errcode = '22023', message = 'lexical search requires query text';
    end if;
    v_match_clause := 'and d.search_text &@~| $4';
    v_score_expression := 'pgroonga_score(d.tableoid, d.ctid)';
    v_order_clause := 'candidate_score desc, modified_at desc, id';
  elsif v_mode = 'uuid' then
    if not (coalesce(btrim(p_query_text), '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
      raise exception using errcode = '22023', message = 'uuid search requires a UUID query';
    end if;
    v_uuid_pattern := '%' || lower(btrim(p_query_text)) || '%';
    v_match_clause := 'and d.json::text like $5';
    v_order_clause := 'modified_at desc, id';
  else
    v_match_clause := '';
    v_order_clause := format('%I %s nulls last, id', v_sort_by, v_sort_direction);
  end if;

  v_sql := format($sql$
    with candidate_rows as (
      select
        d.id,
        d.json,
        d.version,
        d.created_at,
        d.modified_at,
        d.team_id,
        %2$s as model_id,
        %3$s as model_version,
        case when $6 = 'process' then exists (
          select 1
          from private.dataset_display_settings publication
          where publication.dataset_kind = 'process' and publication.is_visible and publication.dataset_id = d.id
            and publication.dataset_version = d.version
        ) else false end as is_published,
        %4$s as candidate_score
      from %1$s d
      where d.state_code = 100
        and ($1 = 'all' or ($1 = 'literature' and d.user_id is null) or ($1 = 'enterprise' and d.user_id is not null))
        and private.open_data_catalog_filter_matches($6, d.json, $3)
        %5$s
    ),
    latest_rows as (
      select distinct on (candidate_rows.id) candidate_rows.*
      from candidate_rows
      order by candidate_rows.id, candidate_rows.version desc, candidate_rows.modified_at desc
    ),
    filtered_rows as (
      select latest_rows.*
      from latest_rows
      where $6 <> 'process'
        or $2 = 'all'
        or ($2 = 'published' and latest_rows.is_published)
        or ($2 = 'unpublished' and not latest_rows.is_published)
    ),
    counted_rows as (
      select filtered_rows.*, count(*) over()::bigint as total_count
      from filtered_rows
    )
    select
      counted_rows.id,
      counted_rows.json,
      counted_rows.version,
      counted_rows.modified_at,
      counted_rows.team_id,
      counted_rows.model_id,
      counted_rows.model_version,
      counted_rows.is_published,
      counted_rows.total_count
    from counted_rows
    order by %6$s
    limit $7
    offset ($8 - 1) * $7
  $sql$, v_table, v_model_id_expression, v_model_version_expression,
    v_score_expression, v_match_clause, v_order_clause);

  return query execute v_sql
    using v_source_filter, v_publication_filter, v_filter, v_terms,
      v_uuid_pattern, v_kind, v_page_size, v_page_current;
end;
$_$;

alter function api.search_open_data_catalog(text, text, text, text[], jsonb, text, text, integer, integer, text, text)
  owner to postgres;
revoke all on function api.search_open_data_catalog(text, text, text, text[], jsonb, text, text, integer, integer, text, text)
  from public, anon, authenticated, service_role;
grant execute on function api.search_open_data_catalog(text, text, text, text[], jsonb, text, text, integer, integer, text, text)
  to anon, authenticated, api_internal_executor;

comment on function api.search_open_data_catalog(text, text, text, text[], jsonb, text, text, integer, integer, text, text) is
  'Lists or searches latest state-100 Open Data rows with source and exact-version Process publication filters applied before count and pagination.';

create or replace function api.hybrid_search_open_data_catalog(
  p_dataset_kind text,
  query_text text,
  query_embedding text,
  filter_condition jsonb default '{}'::jsonb,
  match_threshold double precision default 0.5,
  match_count integer default 20,
  lexical_weight double precision default 0.5,
  semantic_weight double precision default 0.5,
  rrf_k integer default 10,
  page_size integer default 10,
  page_current integer default 1,
  query_terms text[] default null,
  source_filter text default 'all',
  publication_filter text default 'all'
)
returns table (
  id uuid,
  "json" jsonb,
  version character(9),
  modified_at timestamptz,
  team_id uuid,
  model_id uuid,
  model_version character(9),
  is_published boolean,
  total_count bigint
)
language plpgsql
security definer
set search_path to api, private, public, util, extensions, pg_temp
set statement_timeout to '60s'
as $_$
declare
  v_kind text := lower(btrim(coalesce(p_dataset_kind, '')));
  v_source_filter text := lower(btrim(coalesce(source_filter, 'all')));
  v_publication_filter text := lower(btrim(coalesce(publication_filter, 'all')));
  v_table regclass;
  v_model_id_expression text := 'null::uuid';
  v_model_version_expression text := 'null::character(9)';
  v_terms text[];
  v_filter jsonb := coalesce(filter_condition, '{}'::jsonb);
  v_page_size integer := least(greatest(coalesce(page_size, 10), 1), 100);
  v_page_current integer := greatest(coalesce(page_current, 1), 1);
  v_candidate_limit integer := least(greatest(coalesce(match_count, 20), v_page_size) * 10, 2000);
  v_threshold_distance double precision := 1 - least(greatest(coalesce(match_threshold, 0.5), -1), 1);
  v_sql text;
begin
  v_table := case v_kind
    when 'process' then 'public.processes'::regclass
    when 'flow' then 'public.flows'::regclass
    when 'lifecyclemodel' then 'public.lifecyclemodels'::regclass
    when 'contact' then 'public.contacts'::regclass
    when 'source' then 'public.sources'::regclass
    when 'unitgroup' then 'public.unitgroups'::regclass
    when 'flowproperty' then 'public.flowproperties'::regclass
    else null
  end;
  if v_table is null then
    raise exception using errcode = '22023', message = 'unsupported p_dataset_kind';
  end if;
  if v_source_filter not in ('all', 'literature', 'enterprise') then
    raise exception using errcode = '22023', message = 'source_filter must be all, literature, or enterprise';
  end if;
  if v_publication_filter not in ('all', 'published', 'unpublished') then
    raise exception using errcode = '22023', message = 'publication_filter must be all, published, or unpublished';
  end if;
  if v_kind <> 'process' and v_publication_filter <> 'all' then
    raise exception using errcode = '22023', message = 'publication filter is supported only for Process data';
  end if;
  if coalesce(btrim(query_text), '') = '' then
    raise exception using errcode = '22023', message = 'query_text is required';
  end if;

  v_terms := private.pgroonga_escape_query_terms(query_terms);
  if cardinality(v_terms) = 0 then
    v_terms := private.pgroonga_escape_query_terms(array[query_text]);
  end if;
  if v_kind = 'process' then
    v_model_id_expression := 'd.model_id';
    v_model_version_expression := 'd.model_version';
  end if;

  v_sql := format($sql$
    with lexical_candidates as materialized (
      select
        d.id,
        pgroonga_score(d.tableoid, d.ctid) as score
      from %1$s d
      where d.state_code = 100
        and ($1 = 'all' or ($1 = 'literature' and d.user_id is null) or ($1 = 'enterprise' and d.user_id is not null))
        and private.open_data_catalog_filter_matches($5, d.json, $3)
        and d.search_text &@~| $4
      order by score desc, d.modified_at desc, d.id
      limit $7
    ),
    lexical as (
      select
        lexical_candidates.id,
        rank() over (order by max(lexical_candidates.score) desc, lexical_candidates.id)::bigint as lexical_rank
      from lexical_candidates
      group by lexical_candidates.id
    ),
    semantic_candidates as materialized (
      select
        d.id,
        d.embedding_ft <=> $6::extensions.vector(1024) as distance
      from %1$s d
      where d.state_code = 100
        and d.embedding_ft is not null
        and ($1 = 'all' or ($1 = 'literature' and d.user_id is null) or ($1 = 'enterprise' and d.user_id is not null))
        and private.open_data_catalog_filter_matches($5, d.json, $3)
        and (d.embedding_ft <=> $6::extensions.vector(1024)) < $8
      order by d.embedding_ft <=> $6::extensions.vector(1024), d.id
      limit $7
    ),
    semantic as (
      select
        semantic_candidates.id,
        rank() over (order by min(semantic_candidates.distance), semantic_candidates.id)::bigint as semantic_rank
      from semantic_candidates
      group by semantic_candidates.id
    ),
    fused as (
      select
        coalesce(lexical.id, semantic.id) as id,
        coalesce(1.0 / ($9 + lexical.lexical_rank), 0.0) * $10
          + coalesce(1.0 / ($9 + semantic.semantic_rank), 0.0) * $11 as score
      from lexical
      full outer join semantic using (id)
    ),
    visible_rows as (
      select
        d.id,
        d.json,
        d.version,
        d.modified_at,
        d.team_id,
        %2$s as model_id,
        %3$s as model_version,
        case when $5 = 'process' then exists (
          select 1 from private.dataset_display_settings publication
          where publication.dataset_kind = 'process' and publication.is_visible and publication.dataset_id = d.id and publication.dataset_version = d.version
        ) else false end as is_published,
        fused.score
      from %1$s d
      join fused using (id)
      where d.state_code = 100
        and ($1 = 'all' or ($1 = 'literature' and d.user_id is null) or ($1 = 'enterprise' and d.user_id is not null))
        and private.open_data_catalog_filter_matches($5, d.json, $3)
    ),
    latest_rows as (
      select distinct on (visible_rows.id) visible_rows.*
      from visible_rows
      order by visible_rows.id, visible_rows.version desc, visible_rows.modified_at desc
    ),
    filtered_rows as (
      select latest_rows.*
      from latest_rows
      where $5 <> 'process'
        or $2 = 'all'
        or ($2 = 'published' and latest_rows.is_published)
        or ($2 = 'unpublished' and not latest_rows.is_published)
    ),
    counted_rows as (
      select filtered_rows.*, count(*) over()::bigint as total_count
      from filtered_rows
    )
    select
      counted_rows.id,
      counted_rows.json,
      counted_rows.version,
      counted_rows.modified_at,
      counted_rows.team_id,
      counted_rows.model_id,
      counted_rows.model_version,
      counted_rows.is_published,
      counted_rows.total_count
    from counted_rows
    order by counted_rows.score desc, counted_rows.modified_at desc, counted_rows.id
    limit $12
    offset ($13 - 1) * $12
  $sql$, v_table, v_model_id_expression, v_model_version_expression);

  return query execute v_sql
    using v_source_filter, v_publication_filter, v_filter, v_terms, v_kind,
      query_embedding, v_candidate_limit, v_threshold_distance, greatest(coalesce(rrf_k, 10), 1),
      greatest(coalesce(lexical_weight, 0.5), 0), greatest(coalesce(semantic_weight, 0.5), 0),
      v_page_size, v_page_current;
end;
$_$;

alter function api.hybrid_search_open_data_catalog(text, text, text, jsonb, double precision, integer, double precision, double precision, integer, integer, integer, text[], text, text)
  owner to postgres;
revoke all on function api.hybrid_search_open_data_catalog(text, text, text, jsonb, double precision, integer, double precision, double precision, integer, integer, integer, text[], text, text)
  from public, anon, authenticated, service_role;
grant execute on function api.hybrid_search_open_data_catalog(text, text, text, jsonb, double precision, integer, double precision, double precision, integer, integer, integer, text[], text, text)
  to anon, authenticated, api_internal_executor;

comment on function api.hybrid_search_open_data_catalog(text, text, text, jsonb, double precision, integer, double precision, double precision, integer, integer, integer, text[], text, text) is
  'Hybrid Open Data search with source and exact-version Process publication filters applied to lexical and semantic candidates before fusion, count, and pagination.';


delete from private.api_capability_grants where routine_identity='api.cmd_open_data_process_publish_batch(jsonb)';
drop function api.cmd_open_data_process_publish_batch(jsonb);
drop table private.open_data_process_publications;
drop function private.reject_open_data_process_publication_mutation();
notify pgrst,'reload schema';
commit;
