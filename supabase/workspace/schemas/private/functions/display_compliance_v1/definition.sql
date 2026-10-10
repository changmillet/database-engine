CREATE OR REPLACE FUNCTION "private"."display_compliance_v1"("p_kind" "text", "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
declare
  v_value jsonb;
  v_item jsonb;
  v_result jsonb := '[]'::jsonb;
begin
  v_value := case p_kind
    when 'process' then p_json #> '{processDataSet,modellingAndValidation,complianceDeclarations,compliance}'
    when 'flow' then p_json #> '{flowDataSet,modellingAndValidation,complianceDeclarations,compliance}'
    else null
  end;
  for v_item in select private.display_json_items_v1(v_value)
  loop
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'system', private.display_named_reference_v1(v_item -> 'common:referenceToComplianceSystem'),
      'overall', nullif(private.display_scalar_text_v1(v_item -> 'common:approvalOfOverallCompliance'), ''),
      'nomenclature', nullif(private.display_scalar_text_v1(v_item -> 'common:nomenclatureCompliance'), ''),
      'methodological', nullif(private.display_scalar_text_v1(v_item -> 'common:methodologicalCompliance'), ''),
      'review', nullif(private.display_scalar_text_v1(v_item -> 'common:reviewCompliance'), ''),
      'documentation', nullif(private.display_scalar_text_v1(v_item -> 'common:documentationCompliance'), ''),
      'quality', nullif(private.display_scalar_text_v1(v_item -> 'common:qualityCompliance'), '')
    ));
  end loop;
  return v_result;
end
$$;

ALTER FUNCTION "private"."display_compliance_v1"("p_kind" "text", "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_compliance_v1"("p_kind" "text", "p_json" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_compliance_v1"("p_kind" "text", "p_json" "jsonb") TO "postgres";
