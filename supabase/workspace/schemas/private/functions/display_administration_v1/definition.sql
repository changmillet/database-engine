CREATE OR REPLACE FUNCTION "private"."display_administration_v1"("p_kind" "text", "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
declare
  v_admin jsonb;
  v_publication jsonb;
  v_commissioner jsonb;
  v_data_generator jsonb;
  v_data_entry jsonb;
  v_copyright_text text;
  v_copyright boolean;
  v_permalink text;
begin
  v_admin := case p_kind
    when 'process' then p_json #> '{processDataSet,administrativeInformation}'
    when 'flow' then p_json #> '{flowDataSet,administrativeInformation}'
    else null
  end;
  v_publication := v_admin -> 'publicationAndOwnership';
  v_commissioner := v_admin #> '{common:commissionerAndGoal,common:referenceToCommissioner}';
  v_data_generator := v_admin #> '{dataGenerator,common:referenceToPersonOrEntityGeneratingTheDataSet}';
  v_data_entry := v_admin #> '{dataEntryBy,common:referenceToPersonOrEntityEnteringTheData}';
  v_copyright_text := lower(coalesce(
    private.display_scalar_text_v1(v_publication -> 'common:copyright'),
    ''
  ));
  v_copyright := case
    when v_copyright_text in ('true', 'yes', '1') then true
    when v_copyright_text in ('false', 'no', '0') then false
    else null
  end;
  -- No public-origin allowlist exists in v1. A syntactically valid HTTPS URL
  -- is not proof that an authored URI is public rather than a private object
  -- or service locator, so this field stays closed until such a contract lands.
  v_permalink := null;

  return jsonb_build_object(
    'workflowStatus', nullif(private.display_scalar_text_v1(v_publication -> 'common:workflowAndPublicationStatus'), ''),
    'copyright', v_copyright,
    'owner', private.display_named_reference_v1(v_publication -> 'common:referenceToOwnershipOfDataSet'),
    'commissioner', private.display_named_reference_v1(v_commissioner),
    'dataGenerator', private.display_named_reference_v1(v_data_generator),
    'dataEntryBy', private.display_named_reference_v1(v_data_entry),
    'project', private.display_localized_text_v1(v_admin #> '{common:commissionerAndGoal,common:project}'),
    'intendedApplications', private.display_localized_text_v1(v_admin #> '{common:commissionerAndGoal,common:intendedApplications}'),
    'accessRestrictions', private.display_localized_text_v1(v_publication -> 'common:accessRestrictions'),
    'licenseType', nullif(private.display_scalar_text_v1(v_publication -> 'common:licenseType'), ''),
    'registrationNumber', nullif(private.display_scalar_text_v1(v_publication -> 'common:registrationNumber'), ''),
    'lastRevisionAt', private.display_datetime_v1(v_publication ->> 'common:dateOfLastRevision'),
    'permanentDataSetUri', v_permalink,
    'precedingVersion', private.display_named_reference_v1(v_publication -> 'common:referenceToPrecedingDataSetVersion')
  );
end
$$;

ALTER FUNCTION "private"."display_administration_v1"("p_kind" "text", "p_json" "jsonb") OWNER TO "portal_display_executor";

REVOKE ALL ON FUNCTION "private"."display_administration_v1"("p_kind" "text", "p_json" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_administration_v1"("p_kind" "text", "p_json" "jsonb") TO "postgres";
