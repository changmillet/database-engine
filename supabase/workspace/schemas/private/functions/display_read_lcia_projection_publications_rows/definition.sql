CREATE OR REPLACE FUNCTION "private"."display_read_lcia_projection_publications_rows"() RETURNS TABLE("id" "uuid", "projection_id" "uuid", "lcia_result_publication_id" "uuid", "package_id" "uuid", "package_version" "text", "projection_content_hash" "text", "evidence_hash" "text", "source_published_at" timestamp with time zone, "status" "text", "revoked_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$select id,projection_id,lcia_result_publication_id,package_id,package_version,projection_content_hash,evidence_hash,source_published_at,status,revoked_at from private.portal_lcia_projection_publications$$;

ALTER FUNCTION "private"."display_read_lcia_projection_publications_rows"() OWNER TO "portal_public_executor";

REVOKE ALL ON FUNCTION "private"."display_read_lcia_projection_publications_rows"() FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_read_lcia_projection_publications_rows"() TO "portal_display_executor";
