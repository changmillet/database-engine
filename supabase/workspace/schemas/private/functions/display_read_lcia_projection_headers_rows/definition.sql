CREATE OR REPLACE FUNCTION "private"."display_read_lcia_projection_headers_rows"() RETURNS TABLE("id" "uuid", "status" "text", "process_count" integer, "impact_count" integer, "expected_value_count" bigint, "content_hash" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$select id,status,process_count,impact_count,expected_value_count,content_hash from private.portal_lcia_projection_headers$$;

ALTER FUNCTION "private"."display_read_lcia_projection_headers_rows"() OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_read_lcia_projection_headers_rows"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_read_lcia_projection_headers_rows"() TO "portal_display_executor";
