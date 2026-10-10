CREATE OR REPLACE FUNCTION "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
declare
  v_publication jsonb := private.display_publication_root_v1(p_kind, p_json);
  v_license text := private.display_scalar_text_v1(v_publication -> 'common:licenseType');
  v_exclusive jsonb := v_publication -> 'common:referenceToEntitiesWithExclusiveAccess';
  v_restrictions jsonb := v_publication -> 'common:accessRestrictions';
  v_exclusive_missing boolean;
  v_restrictions_open boolean;
  v_open boolean;
  v_reasons jsonb := '[]'::jsonb;
begin
  v_exclusive_missing := v_exclusive is null
    or v_exclusive = 'null'::jsonb;
  v_restrictions_open := private.display_access_restrictions_open_v1(v_restrictions);
  v_open := coalesce(v_license = 'Free of charge for all users and uses'
    and v_exclusive_missing
    and v_restrictions_open, false);

  if v_license is distinct from 'Free of charge for all users and uses' then
    v_reasons := v_reasons || '"license_not_fully_open"'::jsonb;
  end if;
  if not v_exclusive_missing then
    v_reasons := v_reasons || '"exclusive_access_declared"'::jsonb;
  end if;
  if not v_restrictions_open then
    v_reasons := v_reasons || '"access_restrictions_present"'::jsonb;
  end if;
  if v_open then
    v_reasons := '[]'::jsonb || '"public_license_confirmed"'::jsonb;
  end if;

  return jsonb_build_object(
    'metadataVisible', true,
    'exchangesVisible', v_open,
    'lciaVisible', false,
    'publicArtifactVisible', false,
    'citationVisible', true,
    'policyVersion', 'portal-capability-policy.v1',
    'reasonCodes', v_reasons
  );
end
$$;

ALTER FUNCTION "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."display_capabilities_v1"("p_kind" "text", "p_state_code" integer, "p_json" "jsonb") TO "portal_display_executor";
