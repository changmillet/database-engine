CREATE OR REPLACE FUNCTION "private"."portal_display_brand_facets_v1"("p_page" "jsonb", "p_kind" "text", "p_query" "text", "p_filters" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "row_security" TO 'on'
    AS $$
 select jsonb_set(p_page,'{groups}',(p_page->'groups') || jsonb_build_array(jsonb_build_object(
  'id','brand','label',jsonb_build_array(jsonb_build_object('language','en','value','Database brand')),
  'hasMore',false,'values',coalesce((select jsonb_agg(jsonb_build_object(
   'value',brand,'label',jsonb_build_array(jsonb_build_object('language','en','value',private.portal_brand_v1(brand)->>'name')),
   'count',total) order by brand)
   from (select p.brand,count(*) as total
    from private.display_navigation_matched_versions_v1(lower(btrim(p_kind)),lower(btrim(coalesce(p_query,''))),private.display_normalize_filters_v1(p_filters)) k
    join private.display_catalog_search_rows_v1 p using(dataset_kind,id,version)
    group by p.brand) counted),'[]'::jsonb))))
$$;

ALTER FUNCTION "private"."portal_display_brand_facets_v1"("p_page" "jsonb", "p_kind" "text", "p_query" "text", "p_filters" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."portal_display_brand_facets_v1"("p_page" "jsonb", "p_kind" "text", "p_query" "text", "p_filters" "jsonb") FROM PUBLIC;
