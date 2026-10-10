CREATE OR REPLACE FUNCTION "private"."portal_brand_v1"("p_brand" "text") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case p_brand
    when 'tiangong_lca' then pg_catalog.jsonb_build_object('code', p_brand, 'name', 'Tiangong LCA')
    when 'bafu' then pg_catalog.jsonb_build_object('code', p_brand, 'name', 'BAFU')
    when 'uslci' then pg_catalog.jsonb_build_object('code', p_brand, 'name', 'USLCI')
    when 'worldsteel' then pg_catalog.jsonb_build_object('code', p_brand, 'name', 'World steel')
    else null
  end;
$$;

ALTER FUNCTION "private"."portal_brand_v1"("p_brand" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."portal_brand_v1"("p_brand" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."portal_brand_v1"("p_brand" "text") TO "portal_public_executor";

GRANT ALL ON FUNCTION "private"."portal_brand_v1"("p_brand" "text") TO "portal_display_executor";
