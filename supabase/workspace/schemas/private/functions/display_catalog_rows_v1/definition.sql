CREATE OR REPLACE FUNCTION "private"."display_catalog_rows_v1"("p_kind" "text") RETURNS TABLE("id" "uuid", "version" "text", "json_data" "jsonb", "state_code" integer, "modified_at" timestamp with time zone, "lexical_text" "text")
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $$
begin
  if p_kind = 'process' then
    return query
    select row.id, row.version::text, row.json, row.state_code, row.modified_at,
      ''::text
    from public.processes as row
    where private.portal_display_request_visible_v1(p_kind,row.id,row.version::text)
      and jsonb_typeof(row.json) = 'object'
      and jsonb_typeof(row.json -> 'processDataSet') = 'object'
      and row.modified_at is not null;
  elsif p_kind = 'flow' then
    return query
    select row.id, row.version::text, row.json, row.state_code, row.modified_at,
      ''::text
    from public.flows as row
    where private.portal_display_request_visible_v1(p_kind,row.id,row.version::text)
      and jsonb_typeof(row.json) = 'object'
      and jsonb_typeof(row.json -> 'flowDataSet') = 'object'
      and row.modified_at is not null;
  end if;
end
$$;

ALTER FUNCTION "private"."display_catalog_rows_v1"("p_kind" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_catalog_rows_v1"("p_kind" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_catalog_rows_v1"("p_kind" "text") TO "postgres";
