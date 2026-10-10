CREATE OR REPLACE FUNCTION "private"."display_projection_semantic_candidates_v1"("p_kind" "text", "p_query_embedding" "extensions"."vector") RETURNS TABLE("id" "uuid", "version" "text", "semantic_distance" double precision)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "row_security" TO 'on'
    AS $$
begin
  if p_kind = 'process' then
    return query
    select candidate.*
    from private.display_projection_semantic_process_v1(
      p_query_embedding
    ) as candidate;
  elsif p_kind = 'flow' then
    return query
    select candidate.*
    from private.display_projection_semantic_flow_v1(
      p_query_embedding
    ) as candidate;
  end if;
end
$$;

ALTER FUNCTION "private"."display_projection_semantic_candidates_v1"("p_kind" "text", "p_query_embedding" "extensions"."vector") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_semantic_candidates_v1"("p_kind" "text", "p_query_embedding" "extensions"."vector") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_projection_semantic_candidates_v1"("p_kind" "text", "p_query_embedding" "extensions"."vector") TO "postgres";
