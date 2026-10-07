CREATE OR REPLACE FUNCTION "api"."hybrid_search_contacts_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text" DEFAULT ''::"text", "match_threshold" double precision DEFAULT 0.5, "match_count" integer DEFAULT 20, "lexical_weight" double precision DEFAULT 0.5, "semantic_weight" double precision DEFAULT 0.5, "rrf_k" integer DEFAULT 10, "data_source" "text" DEFAULT 'tg'::"text", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "query_terms" "text"[] DEFAULT NULL::"text"[], "state_code_filter" integer DEFAULT NULL::integer, "team_id_filter" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
begin

  -- raw793 bounds: validate original inputs before the existing delegate.
  if page_size > 100 then
    raise exception using errcode='22023',message='Raw search page_size exceeds 100';
  end if;
  if match_count > 100 then
    raise exception using errcode='22023',message='Raw hybrid match_count exceeds 100';
  end if;
  if greatest(coalesce(page_current::bigint,1),1)-1
       > 2147483647::bigint / greatest(coalesce(page_size::bigint,10),1) then
    raise exception using errcode='22023',message='Raw search normalized offset exceeds 2147483647';
  end if;
  -- raw793 bounds end.
  return query

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
end;
$$;

ALTER FUNCTION "api"."hybrid_search_contacts_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text", "match_threshold" double precision, "match_count" integer, "lexical_weight" double precision, "semantic_weight" double precision, "rrf_k" integer, "data_source" "text", "page_size" integer, "page_current" integer, "query_terms" "text"[], "state_code_filter" integer, "team_id_filter" "uuid") OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "api"."hybrid_search_contacts_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text", "match_threshold" double precision, "match_count" integer, "lexical_weight" double precision, "semantic_weight" double precision, "rrf_k" integer, "data_source" "text", "page_size" integer, "page_current" integer, "query_terms" "text"[], "state_code_filter" integer, "team_id_filter" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."hybrid_search_contacts_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text", "match_threshold" double precision, "match_count" integer, "lexical_weight" double precision, "semantic_weight" double precision, "rrf_k" integer, "data_source" "text", "page_size" integer, "page_current" integer, "query_terms" "text"[], "state_code_filter" integer, "team_id_filter" "uuid") TO "anon";

GRANT ALL ON FUNCTION "api"."hybrid_search_contacts_v2"("query_text" "text", "query_embedding" "text", "filter_condition" "text", "match_threshold" double precision, "match_count" integer, "lexical_weight" double precision, "semantic_weight" double precision, "rrf_k" integer, "data_source" "text", "page_size" integer, "page_current" integer, "query_terms" "text"[], "state_code_filter" integer, "team_id_filter" "uuid") TO "authenticated";
