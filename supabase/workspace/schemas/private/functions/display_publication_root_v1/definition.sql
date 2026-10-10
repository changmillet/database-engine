CREATE OR REPLACE FUNCTION "private"."display_publication_root_v1"("p_kind" "text", "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select case p_kind
    when 'process' then p_json #> '{processDataSet,administrativeInformation,publicationAndOwnership}'
    when 'flow' then p_json #> '{flowDataSet,administrativeInformation,publicationAndOwnership}'
    when 'flowproperty' then p_json #> '{flowPropertyDataSet,administrativeInformation,publicationAndOwnership}'
    when 'unitgroup' then p_json #> '{unitGroupDataSet,administrativeInformation,publicationAndOwnership}'
    else null
  end
$$;

ALTER FUNCTION "private"."display_publication_root_v1"("p_kind" "text", "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_publication_root_v1"("p_kind" "text", "p_json" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_publication_root_v1"("p_kind" "text", "p_json" "jsonb") TO "postgres";
