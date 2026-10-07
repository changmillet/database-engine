CREATE OR REPLACE FUNCTION "api"."search_processes_latest_v2"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "order_by" "jsonb" DEFAULT '{}'::"jsonb", "page_size" bigint DEFAULT 10, "page_current" bigint DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer, "type_of_data_set_filter" "text" DEFAULT 'all'::"text", "query_terms" "text"[] DEFAULT NULL::"text"[], "owner_draft_only" boolean DEFAULT false) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "model_id" "uuid", "model_version" character, "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
begin

  -- raw793 bounds: validate original inputs before the existing delegate.
  if page_size > 1000 then
    raise exception using errcode='22023',message='Raw search page_size exceeds 1000';
  end if;
  if greatest(coalesce(page_current::bigint,1),1)-1
       > 2147483647::bigint / greatest(coalesce(page_size::bigint,10),1) then
    raise exception using errcode='22023',message='Raw search normalized offset exceeds 2147483647';
  end if;
  -- raw793 bounds end.
  return query

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
end;
$$;

ALTER FUNCTION "api"."search_processes_latest_v2"("query_text" "text", "filter_condition" "jsonb", "order_by" "jsonb", "page_size" bigint, "page_current" bigint, "data_source" "text", "this_user_id" "text", "team_id_filter" "uuid", "state_code_filter" integer, "type_of_data_set_filter" "text", "query_terms" "text"[], "owner_draft_only" boolean) OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "api"."search_processes_latest_v2"("query_text" "text", "filter_condition" "jsonb", "order_by" "jsonb", "page_size" bigint, "page_current" bigint, "data_source" "text", "this_user_id" "text", "team_id_filter" "uuid", "state_code_filter" integer, "type_of_data_set_filter" "text", "query_terms" "text"[], "owner_draft_only" boolean) FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."search_processes_latest_v2"("query_text" "text", "filter_condition" "jsonb", "order_by" "jsonb", "page_size" bigint, "page_current" bigint, "data_source" "text", "this_user_id" "text", "team_id_filter" "uuid", "state_code_filter" integer, "type_of_data_set_filter" "text", "query_terms" "text"[], "owner_draft_only" boolean) TO "anon";

GRANT ALL ON FUNCTION "api"."search_processes_latest_v2"("query_text" "text", "filter_condition" "jsonb", "order_by" "jsonb", "page_size" bigint, "page_current" bigint, "data_source" "text", "this_user_id" "text", "team_id_filter" "uuid", "state_code_filter" integer, "type_of_data_set_filter" "text", "query_terms" "text"[], "owner_draft_only" boolean) TO "authenticated";
