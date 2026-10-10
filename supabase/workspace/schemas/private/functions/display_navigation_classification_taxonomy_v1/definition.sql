CREATE OR REPLACE FUNCTION "private"."display_navigation_classification_taxonomy_v1"("p_system" "jsonb") RETURNS "text"[]
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case pg_catalog.lower(pg_catalog.btrim(coalesce(
    p_system ->> '#text',
    p_system ->> '@name',
    case when pg_catalog.jsonb_typeof(p_system) = 'string' then p_system #>> '{}' end,
    ''
  )))
    when 'isic' then array['isic']::text[]
    when 'cpc' then array['cpc']::text[]
    when 'elementary-flow' then array['elementary']::text[]
    when 'ilcd-flow-categorization' then array['elementary']::text[]
    when 'ilcd' then array['isic','cpc']::text[]
    else '{}'::text[]
  end;
$$;

ALTER FUNCTION "private"."display_navigation_classification_taxonomy_v1"("p_system" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_navigation_classification_taxonomy_v1"("p_system" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_navigation_classification_taxonomy_v1"("p_system" "jsonb") TO "postgres";
