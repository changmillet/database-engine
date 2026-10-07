CREATE OR REPLACE FUNCTION "api"."search_unitgroups"("query_text" "text", "filter_condition" "jsonb" DEFAULT '{}'::"jsonb", "page_size" integer DEFAULT 10, "page_current" integer DEFAULT 1, "data_source" "text" DEFAULT 'tg'::"text", "this_user_id" "text" DEFAULT ''::"text", "team_id_filter" "uuid" DEFAULT NULL::"uuid", "state_code_filter" integer DEFAULT NULL::integer) RETURNS TABLE("rank" bigint, "id" "uuid", "json" "jsonb", "version" character, "modified_at" timestamp with time zone, "team_id" "uuid", "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
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

ALTER FUNCTION "api"."search_unitgroups"("query_text" "text", "filter_condition" "jsonb", "page_size" integer, "page_current" integer, "data_source" "text", "this_user_id" "text", "team_id_filter" "uuid", "state_code_filter" integer) OWNER TO "api_internal_executor";

REVOKE ALL ON FUNCTION "api"."search_unitgroups"("query_text" "text", "filter_condition" "jsonb", "page_size" integer, "page_current" integer, "data_source" "text", "this_user_id" "text", "team_id_filter" "uuid", "state_code_filter" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."search_unitgroups"("query_text" "text", "filter_condition" "jsonb", "page_size" integer, "page_current" integer, "data_source" "text", "this_user_id" "text", "team_id_filter" "uuid", "state_code_filter" integer) TO "anon";

GRANT ALL ON FUNCTION "api"."search_unitgroups"("query_text" "text", "filter_condition" "jsonb", "page_size" integer, "page_current" integer, "data_source" "text", "this_user_id" "text", "team_id_filter" "uuid", "state_code_filter" integer) TO "authenticated";
