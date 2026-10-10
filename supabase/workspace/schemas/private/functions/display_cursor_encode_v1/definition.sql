CREATE OR REPLACE FUNCTION "private"."display_cursor_encode_v1"("p_payload" "jsonb") RETURNS "text"
    LANGUAGE "sql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select rtrim(
    translate(
      replace(
        replace(encode(convert_to((p_payload || jsonb_build_object('displayScope',private.portal_display_scope_identity_v1()))::text, 'UTF8'), 'base64'), E'\n', ''),
        E'\r',
        ''
      ),
      '+/',
      '-_'
    ),
    '='
  )
$$;

ALTER FUNCTION "private"."display_cursor_encode_v1"("p_payload" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_cursor_encode_v1"("p_payload" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_cursor_encode_v1"("p_payload" "jsonb") TO "postgres";
