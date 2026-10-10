CREATE OR REPLACE FUNCTION "private"."portal_display_settings_sync_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 if tg_op='DELETE' then
  perform private.portal_display_refresh_exact_v1(old.dataset_kind,old.dataset_id,old.dataset_version);
  return old;
 end if;
 if tg_op='UPDATE' and (old.dataset_kind,old.dataset_id,old.dataset_version) is distinct from (new.dataset_kind,new.dataset_id,new.dataset_version) then
  perform private.portal_display_refresh_exact_v1(old.dataset_kind,old.dataset_id,old.dataset_version);
 end if;
 perform private.portal_display_refresh_exact_v1(new.dataset_kind,new.dataset_id,new.dataset_version);
 return new;
end $$;

ALTER FUNCTION "private"."portal_display_settings_sync_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_settings_sync_v1"() FROM PUBLIC;
