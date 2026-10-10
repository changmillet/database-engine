CREATE OR REPLACE FUNCTION "private"."display_dataset_metadata_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL RESTRICTED
    SET "search_path" TO ''
    AS $_$
declare
  v_information jsonb;
  v_modelling jsonb;
  v_location jsonb;
  v_location_code text;
  v_cas text;
begin
  if p_kind = 'process' then
    v_information := p_json #> '{processDataSet,processInformation}';
    v_modelling := p_json #> '{processDataSet,modellingAndValidation}';
    v_location := v_information #> '{geography,locationOfOperationSupplyOrProduction}';
    v_location_code := nullif(
      private.display_scalar_text_v1(v_location -> '@location'),
      ''
    );
    return jsonb_build_object(
      'kind', 'process',
      'names', private.display_process_names_v1(p_json),
      'generalComment', private.display_localized_text_v1(v_information #> '{dataSetInformation,common:generalComment}'),
      'referenceProduct', private.display_process_reference_product_v1(p_json),
      'functionalUnit', private.display_process_functional_unit_v1(p_state_code, p_json),
      'classifications', private.display_classifications_v1(v_information #> '{dataSetInformation,classificationInformation}'),
      'geography', jsonb_build_object(
        'code', v_location_code,
        'label', private.display_localized_text_v1(v_location -> 'descriptionOfRestrictions'),
        'precision', private.display_geography_precision_v1(v_location_code)
      ),
      'referenceYear', private.display_safe_year_v1(v_information #>> '{time,common:referenceYear}'),
      'validUntilYear', private.display_safe_year_v1(v_information #>> '{time,common:dataSetValidUntil}'),
      'technology',
        private.display_localized_text_v1(
          v_information #> '{technology,technologyDescriptionAndIncludedProcesses}'
        ) || private.display_localized_text_v1(
          v_information #> '{technology,technologicalApplicability}'
        ),
      'dataSetType', nullif(private.display_scalar_text_v1(
        v_modelling #> '{LCIMethodAndAllocation,typeOfDataSet}'
      ), ''),
      'allocationAndModeling',
        private.display_localized_text_v1(
          v_modelling #> '{LCIMethodAndAllocation,deviationsFromLCIMethodPrinciple}'
        ) || private.display_localized_text_v1(
          v_modelling #> '{LCIMethodAndAllocation,deviationsFromModellingConstants}'
        ),
      'cutoffRules', private.display_localized_text_v1(
        v_modelling #> '{dataSourcesTreatmentAndRepresentativeness,deviationsFromCutOffAndCompletenessPrinciples}'
      ),
      'quality', jsonb_build_object(
        'reviewStatus', (
          select nullif(private.display_scalar_text_v1(review_item -> '@type'), '')
          from private.display_json_items_v1(v_modelling #> '{validation,review}') as review_item
          limit 1
        ),
        'timeRepresentativeness', private.display_first_text_v1(
          v_information #> '{time,common:timeRepresentativenessDescription}'
        ),
        'geographyRepresentativeness', private.display_first_text_v1(
          v_modelling #> '{dataSourcesTreatmentAndRepresentativeness,geographicalRepresentativenessDescription}'
        ),
        'technologyRepresentativeness', private.display_first_text_v1(
          v_modelling #> '{dataSourcesTreatmentAndRepresentativeness,technologicalRepresentativenessDescription}'
        ),
        'completeness', private.display_first_text_v1(
          v_modelling #> '{completeness,completenessOtherProblemField}'
        ),
        'uncertainty', private.display_first_text_v1(
          v_modelling #> '{dataSourcesTreatmentAndRepresentativeness,uncertaintyAdjustments}'
        )
      ),
      'source', private.display_source_v1('process', p_json),
      'compliance', private.display_compliance_v1('process', p_json),
      'administration', private.display_administration_v1('process', p_json)
    );
  elsif p_kind = 'flow' then
    v_information := p_json #> '{flowDataSet,flowInformation}';
    v_modelling := p_json #> '{flowDataSet,modellingAndValidation}';
    v_location := v_information -> 'geography';
    v_location_code := case jsonb_typeof(v_location -> 'locationOfSupply')
      when 'string' then nullif(
        private.display_scalar_text_v1(v_location -> 'locationOfSupply'),
        ''
      )
      when 'object' then nullif(
        private.display_scalar_text_v1(v_location #> '{locationOfSupply,@location}'),
        ''
      )
      else null
    end;
    v_cas := nullif(btrim(coalesce(
      v_information #>> '{dataSetInformation,CASNumber}',
      v_information #>> '{dataSetInformation,common:CASNumber}'
    )), '');
    if v_cas !~ '^[0-9]{2,7}-[0-9]{2}-[0-9]$' then
      v_cas := null;
    end if;
    return jsonb_build_object(
      'kind', 'flow',
      'names', private.display_localized_text_v1(v_information #> '{dataSetInformation,name,baseName}'),
      'synonyms', private.display_localized_text_v1(v_information #> '{dataSetInformation,common:synonyms}'),
      'generalComment', private.display_localized_text_v1(v_information #> '{dataSetInformation,common:generalComment}'),
      'casNumber', v_cas,
      'flowType', private.display_flow_kind_v1(private.display_scalar_text_v1(
        v_modelling #> '{LCIMethod,typeOfDataSet}'
      )),
      'classifications', private.display_classifications_v1(v_information #> '{dataSetInformation,classificationInformation}'),
      'locationOfSupply', jsonb_build_object(
        'code', v_location_code,
        'label', private.display_localized_text_v1(v_location #> '{locationOfSupply,descriptionOfRestrictions}')
      ),
      'referenceFlowProperty', private.display_reference_flowproperty_v1(p_json),
      'source', private.display_source_v1('flow', p_json),
      'compliance', private.display_compliance_v1('flow', p_json),
      'administration', private.display_administration_v1('flow', p_json)
    );
  end if;
  return null;
end
$_$;

ALTER FUNCTION "private"."display_dataset_metadata_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_dataset_metadata_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_dataset_metadata_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") TO "postgres";
