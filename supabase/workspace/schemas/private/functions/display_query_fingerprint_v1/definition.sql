CREATE OR REPLACE FUNCTION "private"."display_query_fingerprint_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text") RETURNS "text"
    LANGUAGE "sql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'scope', private.portal_display_scope_identity_v1(),
          'kind', p_kind,
          'query', p_query,
          'filters', p_filters,
          'sort', p_sort
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
$$;

ALTER FUNCTION "private"."display_query_fingerprint_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_query_fingerprint_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_query_fingerprint_v1"("p_kind" "text", "p_query" "text", "p_filters" "jsonb", "p_sort" "text") TO "postgres";
