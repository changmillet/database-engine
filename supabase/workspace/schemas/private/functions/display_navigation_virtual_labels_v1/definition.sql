CREATE OR REPLACE FUNCTION "private"."display_navigation_virtual_labels_v1"("p_key" "text") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case p_key
    when 'unclassified' then pg_catalog.jsonb_build_object(
      'en', 'Unclassified', 'zh-CN', '未分类', 'de', 'Nicht klassifiziert', 'fr', 'Non classé'
    )
    else pg_catalog.jsonb_build_object(
      'en', 'Unmapped locations', 'zh-CN', '未映射地区',
      'de', 'Nicht zugeordnete Standorte', 'fr', 'Localisations non mappées'
    )
  end;
$$;

ALTER FUNCTION "private"."display_navigation_virtual_labels_v1"("p_key" "text") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_virtual_labels_v1"("p_key" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_navigation_virtual_labels_v1"("p_key" "text") TO "postgres";
