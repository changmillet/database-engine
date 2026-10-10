CREATE OR REPLACE FUNCTION "private"."display_json_items_v1"("p_value" "jsonb") RETURNS SETOF "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select item.value
  from jsonb_array_elements(
    case jsonb_typeof(p_value)
      when 'array' then p_value
      when 'object' then jsonb_build_array(p_value)
      else '[]'::jsonb
    end
  ) as item(value)
$$;

ALTER FUNCTION "private"."display_json_items_v1"("p_value" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_json_items_v1"("p_value" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_json_items_v1"("p_value" "jsonb") TO "postgres";
