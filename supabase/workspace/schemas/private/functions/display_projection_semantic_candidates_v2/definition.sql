CREATE OR REPLACE FUNCTION "private"."display_projection_semantic_candidates_v2"("p_kind" "text", "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") RETURNS TABLE("id" "uuid", "version" "text", "semantic_distance" double precision)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    SET "statement_timeout" TO '20s'
    SET "row_security" TO 'on'
    AS $$
begin
  if p_kind = 'process' then
    return query select * from private.display_projection_semantic_process_v2(p_query_embedding,p_filters);
  elsif p_kind = 'flow' then
    return query select * from private.display_projection_semantic_flow_v2(p_query_embedding,p_filters);
  else
    raise exception using errcode = '22023', message = 'invalid portal request';
  end if;
end;
$$;

ALTER FUNCTION "private"."display_projection_semantic_candidates_v2"("p_kind" "text", "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_projection_semantic_candidates_v2"("p_kind" "text", "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_projection_semantic_candidates_v2"("p_kind" "text", "p_query_embedding" "extensions"."vector", "p_filters" "jsonb") TO "postgres";
