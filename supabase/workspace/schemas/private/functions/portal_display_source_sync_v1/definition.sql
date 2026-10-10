CREATE OR REPLACE FUNCTION "private"."portal_display_source_sync_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare k text:=tg_argv[0];
begin
 if tg_op='DELETE' then
  delete from private.dataset_display_settings where dataset_kind=k and dataset_id=old.id and dataset_version=old.version::text;
  perform private.portal_display_refresh_exact_v1(k,old.id,old.version::text);
  return old;
 end if;
 if tg_op='UPDATE' and (old.id,old.version) is distinct from (new.id,new.version) then
  delete from private.dataset_display_settings where dataset_kind=k and dataset_id=old.id and dataset_version=old.version::text;
  perform private.portal_display_refresh_exact_v1(k,old.id,old.version::text);
 end if;
 perform private.portal_display_refresh_exact_v1(k,new.id,new.version::text);
 return new;
end $$;

ALTER FUNCTION "private"."portal_display_source_sync_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_source_sync_v1"() FROM PUBLIC;
