CREATE OR REPLACE FUNCTION "private"."portal_dataset_in_brand_scope_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_allowed_brands" "text"[]) RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare v_scope text[] := private.portal_normalize_brand_scope_v1(p_allowed_brands);
begin
  return exists (
    select 1 from private.dataset_display_settings s
    where s.dataset_kind = p_kind and s.dataset_id = p_id
      and s.dataset_version = p_version::character(9)
      and s.is_visible and s.brand = any(v_scope)
      and p_version ~ '^\d{2}\.\d{2}\.\d{3}$'
  );
end;
$_$;

ALTER FUNCTION "private"."portal_dataset_in_brand_scope_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_allowed_brands" "text"[]) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_dataset_in_brand_scope_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_allowed_brands" "text"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_dataset_in_brand_scope_v1"("p_kind" "text", "p_id" "uuid", "p_version" "text", "p_allowed_brands" "text"[]) TO "portal_public_executor";
