CREATE OR REPLACE FUNCTION "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $$
declare
  v_card jsonb;
begin
  v_card := private.display_catalog_card_cn1(
    p_kind,
    p_state_code,
    p_json
  );
  if pg_catalog.jsonb_typeof(v_card) <> 'object' then
    return null;
  end if;
  return pg_catalog.jsonb_build_object(
    'card', v_card,
    'document', coalesce(v_card ->> 'document', '')
  );
end
$$;

ALTER FUNCTION "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_catalog_projection_payload_cn1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") TO "portal_display_executor";
