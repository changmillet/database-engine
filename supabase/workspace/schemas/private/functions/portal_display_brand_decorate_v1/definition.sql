CREATE OR REPLACE FUNCTION "private"."portal_display_brand_decorate_v1"("p_value" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare r jsonb:=p_value; k jsonb; b text; a jsonb; e record;
begin
 if jsonb_typeof(r)='array' then
  select coalesce(jsonb_agg(private.portal_display_brand_decorate_v1(value) order by ord),'[]') into r
  from jsonb_array_elements(r) with ordinality x(value,ord); return r;
 elsif jsonb_typeof(r) is distinct from 'object' then return r; end if;
 k:=r->'key';
 if k->>'kind' in ('process','flow') and k->>'id' is not null and not (r ? 'matches') then
  select brand into b from private.dataset_display_settings
  where dataset_kind=k->>'kind' and dataset_id=(k->>'id')::uuid and dataset_version=k->>'version' and is_visible;
  r:=r||jsonb_build_object('brand',private.portal_brand_v1(b));
 end if;
 foreach b in array array['items','versionGroups','versions','matches'] loop
  if r ? b then r:=jsonb_set(r,array[b],private.portal_display_brand_decorate_v1(r->b)); end if;
 end loop;
 return r;
end $$;

ALTER FUNCTION "private"."portal_display_brand_decorate_v1"("p_value" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_display_brand_decorate_v1"("p_value" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_display_brand_decorate_v1"("p_value" "jsonb") TO "portal_display_executor";
