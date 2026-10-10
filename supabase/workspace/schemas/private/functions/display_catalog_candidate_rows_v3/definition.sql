CREATE OR REPLACE FUNCTION "private"."display_catalog_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") RETURNS TABLE("id" "uuid", "version" "text", "card" "jsonb", "state_code" integer, "modified_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '8s'
    SET "row_security" TO 'on'
    AS $$
  select candidate.id,
    candidate.version,
    candidate.card,
    candidate.state_code,
    candidate.modified_at
  from private.display_catalog_candidate_rows_v2(
    p_kind, p_query, p_exact_id, p_like_pattern
  ) as candidate
$$;

ALTER FUNCTION "private"."display_catalog_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_catalog_candidate_rows_v3"("p_kind" "text", "p_query" "text", "p_exact_id" "uuid", "p_like_pattern" "text") TO "postgres";
