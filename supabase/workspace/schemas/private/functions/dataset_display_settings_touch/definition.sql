CREATE OR REPLACE FUNCTION "private"."dataset_display_settings_touch"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if (new.is_visible, new.brand) is distinct from (old.is_visible, old.brand) then
    new.updated_at := pg_catalog.clock_timestamp();
  end if;
  return new;
end;
$$;

ALTER FUNCTION "private"."dataset_display_settings_touch"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_display_settings_touch"() FROM PUBLIC;
