CREATE OR REPLACE FUNCTION "private"."portal_dataset_is_visible_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
  select exists (
    select 1 from private.dataset_display_settings s
    where s.dataset_kind = p_kind and s.dataset_id = p_id
      and s.dataset_version = p_version::character(9)
      and s.is_visible and p_version ~ '^\d{2}\.\d{2}\.\d{3}$'
  );
$_$;

ALTER FUNCTION "private"."portal_dataset_is_visible_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_dataset_is_visible_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_dataset_is_visible_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text") TO "portal_public_executor";
