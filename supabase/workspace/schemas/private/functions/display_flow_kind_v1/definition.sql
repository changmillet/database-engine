CREATE OR REPLACE FUNCTION "private"."display_flow_kind_v1"("p_type" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case lower(btrim(coalesce(p_type, '')))
    when 'elementary flow' then 'elementary'
    when 'waste flow' then 'waste'
    when 'product flow' then 'product'
    when 'other flow' then 'other'
    else 'unknown'
  end
$$;

ALTER FUNCTION "private"."display_flow_kind_v1"("p_type" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_flow_kind_v1"("p_type" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_flow_kind_v1"("p_type" "text") TO "postgres";
