CREATE OR REPLACE FUNCTION "private"."lcia_package_availability_valid_v1"("p_package_id" "uuid", "p_require_complete" boolean DEFAULT false) RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_package private.lcia_result_packages%rowtype;
  v_result private.lca_results%rowtype;
  v_receipt jsonb;
  v_available jsonb;
begin
  select * into v_package from private.lcia_result_packages where id = p_package_id;
  if v_package.id is null then return false; end if;
  select * into v_result from private.lca_results where id = v_package.result_id;
  v_receipt := private.lcia_registered_result_availability_v1(
    v_package.result_id, v_package.snapshot_id, p_require_complete);
  if v_receipt is null then return false; end if;
  select coalesce(jsonb_agg(category->'method_id' order by ordinality), '[]'::jsonb)
    into v_available
    from jsonb_array_elements(v_receipt->'categories') with ordinality as item(category, ordinality)
    where category->>'status' = 'available';
  return coalesce(v_package.artifact_manifest->'lciaAvailability' is not distinct from v_receipt
    and v_result.job_id is not distinct from v_package.build_id
    and v_result.worker_job_id is not distinct from v_package.build_worker_job_id
    and v_result.artifact_sha256 ~ '^[0-9a-f]{64}$'
    and v_package.package_result_hash is not distinct from v_result.artifact_sha256
    and v_package.result_artifact_ref->>'artifactSha256' is not distinct from v_result.artifact_sha256
    and v_package.artifact_manifest->'calculationBundle' is not distinct from v_result.diagnostics->'calculation_bundle'
    and v_result.diagnostics->'calculation_bundle'->>'schemaVersion' = case
      when v_receipt->>'completeness' = 'complete' then 'tiangong.calculation-bundle.v2'
      else 'tiangong.calculation-bundle.v3' end
    and v_package.available_impact_categories is not distinct from v_available
    and (v_package.default_impact_category is null or v_available ? v_package.default_impact_category),false);
end
$_$;

ALTER FUNCTION "private"."lcia_package_availability_valid_v1"("p_package_id" "uuid", "p_require_complete" boolean) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."lcia_package_availability_valid_v1"("p_package_id" "uuid", "p_require_complete" boolean) FROM PUBLIC;
