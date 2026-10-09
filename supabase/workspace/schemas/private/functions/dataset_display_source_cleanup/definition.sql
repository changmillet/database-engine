CREATE OR REPLACE FUNCTION "private"."dataset_display_source_cleanup"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if TG_OP='DELETE' or new.id is distinct from old.id or new.version is distinct from old.version then
    delete from private.dataset_display_settings where dataset_kind=TG_ARGV[0] and dataset_id=old.id and dataset_version=old.version;
  end if;
  return null;
end; $$;

ALTER FUNCTION "private"."dataset_display_source_cleanup"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."dataset_display_source_cleanup"() FROM PUBLIC;
