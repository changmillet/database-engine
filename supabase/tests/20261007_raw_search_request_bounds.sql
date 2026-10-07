-- Database #793: all 29 exposed raw facades, exact pre-change delegates,
-- full-row differential results, upper edges and overflow failures. Rollback only.
-- SQL baselines have the original body/defaults/security owner/config; changing
-- only the API language to PL/pgSQL enables validation before heavy retrieval.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public,api,private,auth;
select extensions.no_plan();
create temp table raw793_fixture_marker(n integer) on commit drop;
-- Test baselines keep the real owner; borrow SET only within this rollback.
grant api_internal_executor to postgres with inherit false,set true;
do $baseline_temp_access$
begin
  execute pg_catalog.format('grant usage,create on schema %I to api_internal_executor',
    (select nspname from pg_catalog.pg_namespace where oid=pg_catalog.pg_my_temp_schema()));
  execute pg_catalog.format('grant usage on schema %I to authenticated',
    (select nspname from pg_catalog.pg_namespace where oid=pg_catalog.pg_my_temp_schema()));
end;
$baseline_temp_access$;
set local session_replication_role=replica;
insert into auth.users(id,instance_id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values ('79300000-0000-4000-8000-000000000901','00000000-0000-0000-0000-000000000000','authenticated','authenticated','raw793@example.invalid','{}','{}',now(),now());
insert into private.users(id,raw_user_meta_data) values ('79300000-0000-4000-8000-000000000901','{}');
insert into public.flows(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000001','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,1,'||array_to_string(array_fill('0'::text,array[1022]),',')||']')::extensions.vector(1024),'2026-01-01'::timestamptz);
insert into public.flows(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000002','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,'||array_to_string(array_fill('0'::text,array[1023]),',')||']')::extensions.vector(1024),'2026-01-02'::timestamptz);
insert into public.processes(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000001','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,1,'||array_to_string(array_fill('0'::text,array[1022]),',')||']')::extensions.vector(1024),'2026-01-01'::timestamptz);
insert into public.processes(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000002','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,'||array_to_string(array_fill('0'::text,array[1023]),',')||']')::extensions.vector(1024),'2026-01-02'::timestamptz);
insert into public.lifecyclemodels(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000001','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,1,'||array_to_string(array_fill('0'::text,array[1022]),',')||']')::extensions.vector(1024),'2026-01-01'::timestamptz);
insert into public.lifecyclemodels(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000002','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,'||array_to_string(array_fill('0'::text,array[1023]),',')||']')::extensions.vector(1024),'2026-01-02'::timestamptz);
insert into public.contacts(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000001','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,1,'||array_to_string(array_fill('0'::text,array[1022]),',')||']')::extensions.vector(1024),'2026-01-01'::timestamptz);
insert into public.contacts(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000002','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,'||array_to_string(array_fill('0'::text,array[1023]),',')||']')::extensions.vector(1024),'2026-01-02'::timestamptz);
insert into public.flowproperties(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000001','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,1,'||array_to_string(array_fill('0'::text,array[1022]),',')||']')::extensions.vector(1024),'2026-01-01'::timestamptz);
insert into public.flowproperties(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000002','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,'||array_to_string(array_fill('0'::text,array[1023]),',')||']')::extensions.vector(1024),'2026-01-02'::timestamptz);
insert into public.sources(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000001','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,1,'||array_to_string(array_fill('0'::text,array[1022]),',')||']')::extensions.vector(1024),'2026-01-01'::timestamptz);
insert into public.sources(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000002','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,'||array_to_string(array_fill('0'::text,array[1023]),',')||']')::extensions.vector(1024),'2026-01-02'::timestamptz);
insert into public.unitgroups(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000001','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,1,'||array_to_string(array_fill('0'::text,array[1022]),',')||']')::extensions.vector(1024),'2026-01-01'::timestamptz);
insert into public.unitgroups(id,version,user_id,state_code,json,json_ordered,search_text,embedding_ft,modified_at) values ('79300000-0000-4000-8000-000000000002','01.00.000','79300000-0000-4000-8000-000000000901',100,'{"raw793":"fixture"}','{"raw793":"fixture"}',array['raw793fixture'],('[1,'||array_to_string(array_fill('0'::text,array[1023]),',')||']')::extensions.vector(1024),'2026-01-02'::timestamptz);
set local session_replication_role=origin;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_contacts"("query_text" "text", "query_embedding" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[], "state_code_filter" integer DEFAULT NULL::integer, "team_id_filter" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_simple_dataset_v2('public.contacts'::regclass,
    query_text,
    query_embedding,
    filter_condition::text,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms,
    state_code_filter,
    team_id_filter
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_contacts(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_contacts(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_contacts_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text" DEFAULT ''::"text", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[], "state_code_filter" integer DEFAULT NULL::integer, "team_id_filter" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_simple_dataset_v2('public.contacts'::regclass,
    query_text,
    query_embedding,
    filter_condition,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms,
    state_code_filter,
    team_id_filter
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_contacts_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_contacts_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_flowproperties"("query_text" "text", "query_embedding" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[], "state_code_filter" integer DEFAULT NULL::integer, "team_id_filter" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_simple_dataset_v2('public.flowproperties'::regclass,
    query_text,
    query_embedding,
    filter_condition::text,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms,
    state_code_filter,
    team_id_filter
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_flowproperties(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_flowproperties(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_flowproperties_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text" DEFAULT ''::"text", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[], "state_code_filter" integer DEFAULT NULL::integer, "team_id_filter" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_simple_dataset_v2('public.flowproperties'::regclass,
    query_text,
    query_embedding,
    filter_condition,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms,
    state_code_filter,
    team_id_filter
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_flowproperties_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_flowproperties_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_flows"("query_text" "text", "query_embedding" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_flows_v2_impl(
    query_text,
    query_embedding,
    filter_condition::text,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_flows(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_flows(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_flows_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text" DEFAULT ''::"text", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_flows_v2_impl(
    query_text,
    query_embedding,
    filter_condition,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_flows_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_flows_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_lifecyclemodels"("query_text" "text", "query_embedding" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_lifecyclemodels_v2_impl(
    query_text,
    query_embedding,
    filter_condition::text,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_lifecyclemodels(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_lifecyclemodels(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_lifecyclemodels_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text" DEFAULT ''::"text", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_lifecyclemodels_v2_impl(
    query_text,
    query_embedding,
    filter_condition,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_lifecyclemodels_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_lifecyclemodels_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_processes"("query_text" "text", "query_embedding" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "model_id" "uuid", "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_processes_v2_impl(
    query_text,
    query_embedding,
    filter_condition::text,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_processes(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_processes(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_processes_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text" DEFAULT ''::"text", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "model_id" "uuid", "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_processes_v2_impl(
    query_text,
    query_embedding,
    filter_condition,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_processes_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_processes_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_sources"("query_text" "text", "query_embedding" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[], "state_code_filter" integer DEFAULT NULL::integer, "team_id_filter" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_simple_dataset_v2('public.sources'::regclass,
    query_text,
    query_embedding,
    filter_condition::text,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms,
    state_code_filter,
    team_id_filter
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_sources(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_sources(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_sources_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text" DEFAULT ''::"text", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[], "state_code_filter" integer DEFAULT NULL::integer, "team_id_filter" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_simple_dataset_v2('public.sources'::regclass,
    query_text,
    query_embedding,
    filter_condition,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms,
    state_code_filter,
    team_id_filter
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_sources_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_sources_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_unitgroups"("query_text" "text", "query_embedding" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[], "state_code_filter" integer DEFAULT NULL::integer, "team_id_filter" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_simple_dataset_v2('public.unitgroups'::regclass,
    query_text,
    query_embedding,
    filter_condition::text,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms,
    state_code_filter,
    team_id_filter
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_unitgroups(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_unitgroups(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_hybrid_search_unitgroups_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text" DEFAULT ''::"text", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[], "state_code_filter" integer DEFAULT NULL::integer, "team_id_filter" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select *
  from private.hybrid_search_simple_dataset_v2('public.unitgroups'::regclass,
    query_text,
    query_embedding,
    filter_condition,
    match_threshold,
    match_count,
    lexical_weight,
    semantic_weight,
    rrf_k,
    data_source,
    page_size,
    page_current,
    query_terms,
    state_code_filter,
    team_id_filter
  );
$$;
grant execute on function pg_temp.raw793_before_hybrid_search_unitgroups_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) to anon,authenticated;
alter function pg_temp.raw793_before_hybrid_search_unitgroups_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_contacts"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from api._search_simple_dataset_latest(
      'public.contacts'::regclass,
      query_text,
      filter_condition,
      page_size::bigint,
      page_current::bigint,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_contacts(text,jsonb,integer,integer,text,text,uuid,integer) to anon,authenticated;
alter function pg_temp.raw793_before_search_contacts(text,jsonb,integer,integer,text,text,uuid,integer) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_contacts_latest"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" bigint DEFAULT 10, "page_current" bigint DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from api._search_simple_dataset_latest(
      'public.contacts'::regclass,
      query_text,
      filter_condition,
      page_size,
      page_current,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_contacts_latest(text,jsonb,bigint,bigint,text,text,uuid,integer) to anon,authenticated;
alter function pg_temp.raw793_before_search_contacts_latest(text,jsonb,bigint,bigint,text,text,uuid,integer) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_flowproperties"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from api._search_simple_dataset_latest(
      'public.flowproperties'::regclass,
      query_text,
      filter_condition,
      page_size::bigint,
      page_current::bigint,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_flowproperties(text,jsonb,integer,integer,text,text,uuid,integer) to anon,authenticated;
alter function pg_temp.raw793_before_search_flowproperties(text,jsonb,integer,integer,text,text,uuid,integer) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_flowproperties_latest"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" bigint DEFAULT 10, "page_current" bigint DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from api._search_simple_dataset_latest(
      'public.flowproperties'::regclass,
      query_text,
      filter_condition,
      page_size,
      page_current,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_flowproperties_latest(text,jsonb,bigint,bigint,text,text,uuid,integer) to anon,authenticated;
alter function pg_temp.raw793_before_search_flowproperties_latest(text,jsonb,bigint,bigint,text,text,uuid,integer) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_flows"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer, "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from private.search_flows_latest_impl(
      query_text,
      filter_condition,
      page_size::bigint,
      page_current::bigint,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter,
      query_terms
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_flows(text,jsonb,integer,integer,text,text,uuid,integer,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_search_flows(text,jsonb,integer,integer,text,text,uuid,integer,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_flows_latest"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "order_by" "jsonb" DEFAULT '{}'::"jsonb", "page_size" bigint DEFAULT 10, "page_current" bigint DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer, "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from private.search_flows_latest_impl(
      query_text,
      filter_condition,
      page_size,
      page_current,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter,
      query_terms
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_flows_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_search_flows_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_lifecyclemodels"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer, "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from private.search_lifecyclemodels_latest_impl(
      query_text,
      filter_condition,
      page_size::bigint,
      page_current::bigint,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter,
      query_terms
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_lifecyclemodels(text,jsonb,integer,integer,text,text,uuid,integer,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_search_lifecyclemodels(text,jsonb,integer,integer,text,text,uuid,integer,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_lifecyclemodels_latest"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "order_by" "jsonb" DEFAULT '{}'::"jsonb", "page_size" bigint DEFAULT 10, "page_current" bigint DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer, "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from private.search_lifecyclemodels_latest_impl(
      query_text,
      filter_condition,
      page_size,
      page_current,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter,
      query_terms
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_lifecyclemodels_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_search_lifecyclemodels_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_processes"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer, "type_of_data_set_filter" "text" DEFAULT 'all'::"text", "query_terms" "text"[] DEFAULT NULL::"text"[], "owner_draft_only" boolean DEFAULT false) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "model_id" "uuid", "model_version" character, "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select
    result.rank,
    result.id,
    result.json,
    result.version,
    result.modified_at,
    result.team_id,
    result.model_id,
    process.model_version,
    result.total_count
  from private.search_processes_latest_v2_impl(
    query_text,
    filter_condition,
    page_size::bigint,
    page_current::bigint,
    data_source,
    this_user_id,
    team_id_filter,
    state_code_filter,
    type_of_data_set_filter,
    query_terms,
    owner_draft_only
  ) as result
  left join public.processes as process
    on process.id = result.id
   and process.version = result.version;
$$;
grant execute on function pg_temp.raw793_before_search_processes(text,jsonb,integer,integer,text,text,uuid,integer,text,text[],boolean) to anon,authenticated;
alter function pg_temp.raw793_before_search_processes(text,jsonb,integer,integer,text,text,uuid,integer,text,text[],boolean) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_processes_latest"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "order_by" "jsonb" DEFAULT '{}'::"jsonb", "page_size" bigint DEFAULT 10, "page_current" bigint DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer, "type_of_data_set_filter" "text" DEFAULT 'all'::"text", "query_terms" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "model_id" "uuid", "model_version" character, "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select
    result.rank,
    result.id,
    result.json,
    result.version,
    result.modified_at,
    result.team_id,
    result.model_id,
    process.model_version,
    result.total_count
  from private.search_processes_latest_v2_impl(
    query_text, filter_condition, page_size, page_current, data_source,
    this_user_id, team_id_filter, state_code_filter, type_of_data_set_filter,
    query_terms, false
  ) as result
  left join public.processes as process
    on process.id = result.id
   and process.version = result.version
$$;
grant execute on function pg_temp.raw793_before_search_processes_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text,text[]) to anon,authenticated;
alter function pg_temp.raw793_before_search_processes_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text,text[]) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_processes_latest_v2"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "order_by" "jsonb" DEFAULT '{}'::"jsonb", "page_size" bigint DEFAULT 10, "page_current" bigint DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer, "type_of_data_set_filter" "text" DEFAULT 'all'::"text", "query_terms" "text"[] DEFAULT NULL::"text"[], "owner_draft_only" boolean DEFAULT false) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "model_id" "uuid", "model_version" character, "total_count" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
  select
    result.rank,
    result.id,
    result.json,
    result.version,
    result.modified_at,
    result.team_id,
    result.model_id,
    process.model_version,
    result.total_count
  from private.search_processes_latest_v2_impl(
    query_text,
    filter_condition,
    page_size,
    page_current,
    data_source,
    this_user_id,
    team_id_filter,
    state_code_filter,
    type_of_data_set_filter,
    query_terms,
    owner_draft_only
  ) as result
  left join public.processes as process
    on process.id = result.id
   and process.version = result.version;
$$;
grant execute on function pg_temp.raw793_before_search_processes_latest_v2(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text,text[],boolean) to anon,authenticated;
alter function pg_temp.raw793_before_search_processes_latest_v2(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text,text[],boolean) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_sources"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from api._search_simple_dataset_latest(
      'public.sources'::regclass,
      query_text,
      filter_condition,
      page_size::bigint,
      page_current::bigint,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_sources(text,jsonb,integer,integer,text,text,uuid,integer) to anon,authenticated;
alter function pg_temp.raw793_before_search_sources(text,jsonb,integer,integer,text,text,uuid,integer) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_sources_latest"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" bigint DEFAULT 10, "page_current" bigint DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from api._search_simple_dataset_latest(
      'public.sources'::regclass,
      query_text,
      filter_condition,
      page_size,
      page_current,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_sources_latest(text,jsonb,bigint,bigint,text,text,uuid,integer) to anon,authenticated;
alter function pg_temp.raw793_before_search_sources_latest(text,jsonb,bigint,bigint,text,text,uuid,integer) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_unitgroups"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from api._search_simple_dataset_latest(
      'public.unitgroups'::regclass,
      query_text,
      filter_condition,
      page_size::bigint,
      page_current::bigint,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_unitgroups(text,jsonb,integer,integer,text,text,uuid,integer) to anon,authenticated;
alter function pg_temp.raw793_before_search_unitgroups(text,jsonb,integer,integer,text,text,uuid,integer) owner to api_internal_executor;
CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_search_unitgroups_latest"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" bigint DEFAULT 10, "page_current" bigint DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    AS $$
begin
  return query
    select *
    from api._search_simple_dataset_latest(
      'public.unitgroups'::regclass,
      query_text,
      filter_condition,
      page_size,
      page_current,
      data_source,
      this_user_id,
      team_id_filter,
      state_code_filter
    );
end;
$$;
grant execute on function pg_temp.raw793_before_search_unitgroups_latest(text,jsonb,bigint,bigint,text,text,uuid,integer) to anon,authenticated;
alter function pg_temp.raw793_before_search_unitgroups_latest(text,jsonb,bigint,bigint,text,text,uuid,integer) owner to api_internal_executor;
create function pg_temp.raw793_outcome(p_query text) returns jsonb language plpgsql as $$
declare result jsonb;
begin
  execute 'select coalesce(jsonb_agg(to_jsonb(r)-''ordinality'' order by r.ordinality),''[]''::jsonb) from '||substring(p_query from length('select * from ')+1)||' with ordinality as r' into result;
  return jsonb_build_object('rows',result);
exception when others then
  return jsonb_build_object('sqlstate',sqlstate);
end;
$$;
grant execute on function pg_temp.raw793_outcome(text) to anon,authenticated;
create temp table raw793_test_targets(name text,signature text,hybrid boolean,page_cap integer) on commit drop;
insert into raw793_test_targets values
('hybrid_search_contacts','api.hybrid_search_contacts(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)',true,100),
('hybrid_search_contacts_v2','api.hybrid_search_contacts_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)',true,100),
('hybrid_search_flowproperties','api.hybrid_search_flowproperties(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)',true,100),
('hybrid_search_flowproperties_v2','api.hybrid_search_flowproperties_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)',true,100),
('hybrid_search_flows','api.hybrid_search_flows(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])',true,100),
('hybrid_search_flows_v2','api.hybrid_search_flows_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])',true,100),
('hybrid_search_lifecyclemodels','api.hybrid_search_lifecyclemodels(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])',true,100),
('hybrid_search_lifecyclemodels_v2','api.hybrid_search_lifecyclemodels_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])',true,100),
('hybrid_search_processes','api.hybrid_search_processes(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])',true,100),
('hybrid_search_processes_v2','api.hybrid_search_processes_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[])',true,100),
('hybrid_search_sources','api.hybrid_search_sources(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)',true,100),
('hybrid_search_sources_v2','api.hybrid_search_sources_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)',true,100),
('hybrid_search_unitgroups','api.hybrid_search_unitgroups(text,text,jsonb,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)',true,100),
('hybrid_search_unitgroups_v2','api.hybrid_search_unitgroups_v2(text,text,text,double precision,integer,double precision,double precision,integer,text,integer,integer,text[],integer,uuid)',true,100),
('search_contacts','api.search_contacts(text,jsonb,integer,integer,text,text,uuid,integer)',false,1000),
('search_contacts_latest','api.search_contacts_latest(text,jsonb,bigint,bigint,text,text,uuid,integer)',false,1000),
('search_flowproperties','api.search_flowproperties(text,jsonb,integer,integer,text,text,uuid,integer)',false,1000),
('search_flowproperties_latest','api.search_flowproperties_latest(text,jsonb,bigint,bigint,text,text,uuid,integer)',false,1000),
('search_flows','api.search_flows(text,jsonb,integer,integer,text,text,uuid,integer,text[])',false,1000),
('search_flows_latest','api.search_flows_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text[])',false,1000),
('search_lifecyclemodels','api.search_lifecyclemodels(text,jsonb,integer,integer,text,text,uuid,integer,text[])',false,1000),
('search_lifecyclemodels_latest','api.search_lifecyclemodels_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text[])',false,1000),
('search_processes','api.search_processes(text,jsonb,integer,integer,text,text,uuid,integer,text,text[],boolean)',false,1000),
('search_processes_latest','api.search_processes_latest(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text,text[])',false,1000),
('search_processes_latest_v2','api.search_processes_latest_v2(text,jsonb,jsonb,bigint,bigint,text,text,uuid,integer,text,text[],boolean)',false,1000),
('search_sources','api.search_sources(text,jsonb,integer,integer,text,text,uuid,integer)',false,1000),
('search_sources_latest','api.search_sources_latest(text,jsonb,bigint,bigint,text,text,uuid,integer)',false,1000),
('search_unitgroups','api.search_unitgroups(text,jsonb,integer,integer,text,text,uuid,integer)',false,1000),
('search_unitgroups_latest','api.search_unitgroups_latest(text,jsonb,bigint,bigint,text,text,uuid,integer)',false,1000);

create function pg_temp.raw793_run_checks() returns setof text language plpgsql as $test$
declare t record; c record; args text; query text; before_query text; actual jsonb; expected jsonb;
  vector text := '(''[1,''||array_to_string(array_fill(''0''::text,array[1023]),'','')||'']'')';
begin
  for t in select * from pg_temp.raw793_test_targets order by name loop
    args:='query_text=>''raw793fixture'''||case when t.hybrid then ',query_embedding=>'||vector else '' end;
    for c in select * from (values
      ('defaults',''),('explicit normal','page_size=>10,page_current=>1'),
      ('NULL','page_size=>NULL,page_current=>NULL'||case when t.hybrid then ',match_count=>NULL' else '' end),
      ('nonpositive','page_size=>0,page_current=>-7'||case when t.hybrid then ',match_count=>0' else '' end),
      ('upper page edge','page_size=>'||t.page_cap)
    ) cases(label,extra) loop
      query:=format('select * from api.%I(%s%s)',t.name,args,case when c.extra='' then '' else ','||c.extra end);
      before_query:=replace(query,'api.'||t.name||'(','pg_temp.raw793_before_'||t.name||'(');
      actual:=pg_temp.raw793_outcome(query);
      expected:=pg_temp.raw793_outcome(before_query);
      return next extensions.ok(actual ? 'rows',t.name||' '||c.label||' accepted current call succeeds');
      return next extensions.ok(expected ? 'rows',t.name||' '||c.label||' accepted predecessor call succeeds');
      return next extensions.is(jsonb_array_length(actual->'rows'),case when c.label='nonpositive' then 1 else 2 end,t.name||' '||c.label||' current admitted row count');
      return next extensions.is(jsonb_array_length(expected->'rows'),case when c.label='nonpositive' then 1 else 2 end,t.name||' '||c.label||' predecessor admitted row count');
      return next extensions.is(actual,expected,t.name||' '||c.label||' complete ordered payload parity');
      -- The three Process lexical facades LEFT JOIN model_version without an
      -- outer ORDER BY. Preserve their complete emitted predecessor order above;
      -- do not invent a modified_at ordering contract for that joined result.
      if c.label='defaults' and t.name not in
        ('search_processes','search_processes_latest','search_processes_latest_v2') then
        return next extensions.is(actual->'rows'->0->>'id','79300000-0000-4000-8000-000000000002',t.name||' newer/higher-ID default order differs from ID sort');
      end if;
    end loop;
    query:=format('select * from api.%I(%s)',t.name,args);
    return next extensions.ok((pg_temp.raw793_outcome(query)->'rows') @> '[{"id":"79300000-0000-4000-8000-000000000001"}]'::jsonb,t.name||' normal result contains the owned fixture');
    for c in select * from (values
      ('oversized page','page_size=>'||(t.page_cap+1)),
      ('int32 page MAX','page_size=>2147483647'),
      ('offset overflow','page_size=>10,page_current=>2147483647')
    ) cases(label,extra) loop
      query:=format('select * from api.%I(%s,%s)',t.name,
        case when t.hybrid then 'query_text=>''raw793fixture'',query_embedding=>''invalid vector''' else args end,c.extra);
      return next extensions.is(pg_temp.raw793_outcome(query)->>'sqlstate','22023',t.name||' '||c.label||' fails before retrieval');
    end loop;
    if t.hybrid then
      foreach query in array array['match_count=>101','match_count=>2147483647'] loop
        return next extensions.is(pg_temp.raw793_outcome(format('select * from api.%I(query_text=>''raw793fixture'',query_embedding=>''invalid vector'',%s)',t.name,query))->>'sqlstate','22023',t.name||' '||query||' rejects recall before vector cast');
      end loop;
    elsif t.name like '%_latest%' then
      foreach query in array array['page_size=>9223372036854775807','page_size=>1,page_current=>9223372036854775807'] loop
        return next extensions.is(pg_temp.raw793_outcome(format('select * from api.%I(%s,%s)',t.name,args,query))->>'sqlstate','22023',t.name||' '||query||' rejects bigint MAX without overflow');
      end loop;
    end if;
    return next extensions.lives_ok(format('select * from api.%I(%s,page_size=>1,page_current=>2147483647)',t.name,args),t.name||' INT_MAX one-row page remains arithmetic-safe');
    return next extensions.lives_ok(format('select * from api.%I(%s,page_size=>%s,page_current=>%s)',t.name,args,t.page_cap,2147483647/t.page_cap+1),t.name||' last cap-sized offset page is accepted');
    return next extensions.is(pg_temp.raw793_outcome(format('select * from api.%I(%s,page_size=>%s,page_current=>%s)',t.name,args,t.page_cap,2147483647/t.page_cap+2))->>'sqlstate','22023',t.name||' next cap-sized offset page is rejected without multiplication');
    return next extensions.is((select proowner::regrole::text from pg_catalog.pg_proc where oid=t.signature::regprocedure),'api_internal_executor',t.name||' owner retained');
    return next extensions.ok((select prosecdef from pg_catalog.pg_proc where oid=t.signature::regprocedure),t.name||' definer mode retained');
    return next extensions.ok(not exists(select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a where p.oid=t.signature::regprocedure and a.grantee=0),t.name||' PUBLIC stays closed');
  end loop;
  for t in select * from pg_temp.raw793_test_targets where name in ('hybrid_search_flows','hybrid_search_processes','hybrid_search_lifecyclemodels') loop
    for c in select * from (values(20),(80),(100)) sizes(n) loop
      return next extensions.lives_ok(format('select * from api.%I(query_text=>''raw793fixture'',query_embedding=>%s,match_count=>%s,page_size=>%s)',t.name,vector,c.n,c.n),t.name||' recall '||c.n||' preserves 10x lexical budget '||(c.n*10));
    end loop;
  end loop;
  -- Legacy raw kernels multiply the original negative candidate count before
  -- normalization. Their paired INT_MIN inputs intentionally remain invalid;
  -- this is error compatibility, never an accepted-case success assertion.
  for t in select * from pg_temp.raw793_test_targets where name in
    ('hybrid_search_flows','hybrid_search_flows_v2','hybrid_search_processes','hybrid_search_processes_v2','hybrid_search_lifecyclemodels','hybrid_search_lifecyclemodels_v2') loop
    query:=format('select * from api.%I(query_text=>''raw793fixture'',query_embedding=>%s,page_size=>-2147483648,match_count=>-2147483648)',t.name,vector);
    before_query:=replace(query,'api.'||t.name||'(','pg_temp.raw793_before_'||t.name||'(');
    return next extensions.is(pg_temp.raw793_outcome(query)->>'sqlstate','22003',t.name||' intentional paired INT_MIN predecessor error retained');
    return next extensions.is(pg_temp.raw793_outcome(before_query)->>'sqlstate','22003',t.name||' predecessor paired INT_MIN is explicitly invalid');
  end loop;
  foreach query in array array['search_flows','search_processes'] loop
    return next extensions.lives_ok(format('select * from api.%I(query_text=>''raw793fixture'',page_size=>99,page_current=>1000000)',query),query||' Analysis99/deep page beyond400 remains valid');
  end loop;
end;
$test$;
grant select on table raw793_test_targets to authenticated;
grant execute on function pg_temp.raw793_run_checks() to authenticated;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"79300000-0000-4000-8000-000000000901","role":"authenticated"}',true);
select * from pg_temp.raw793_run_checks();
select extensions.is((select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
 where n.nspname='api' and p.proname~'^(hybrid_search_(contacts|flowproperties|flows|lifecyclemodels|processes|sources|unitgroups)(_v2)?|search_(contacts|flowproperties|flows|lifecyclemodels|processes|sources|unitgroups)(_latest)?|search_processes_latest_v2)$'
 and p.prolang=(select oid from pg_catalog.pg_language where lanname='plpgsql')),29::bigint,'all 29 facades validate before retrieval');
reset role;
set local role anon;
select extensions.throws_ok('select * from api.search_flows(query_text=>''raw793fixture'',page_size=>1001)','22023','Raw search page_size exceeds 1000','anonymous facade enforces lexical upper bound');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"79300000-0000-4000-8000-000000000901","role":"authenticated"}',true);
select extensions.throws_ok('select * from api.hybrid_search_flows(query_text=>''raw793fixture'',query_embedding=>''invalid vector'',match_count=>101)','22023','Raw hybrid match_count exceeds 100','authenticated facade rejects recall before embedding cast');
reset role;
select * from extensions.finish();
rollback;
