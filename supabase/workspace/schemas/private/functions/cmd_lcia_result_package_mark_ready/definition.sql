CREATE OR REPLACE FUNCTION "private"."cmd_lcia_result_package_mark_ready"("p_build_worker_job_id" "uuid", "p_package_version" "text", "p_snapshot_id" "uuid", "p_result_id" "uuid", "p_latest_all_unit_result_id" "uuid" DEFAULT NULL::"uuid", "p_result_artifact_ref" "jsonb" DEFAULT '{}'::"jsonb", "p_query_artifact_ref" "jsonb" DEFAULT '{}'::"jsonb", "p_artifact_manifest" "jsonb" DEFAULT '{}'::"jsonb", "p_available_impact_categories" "jsonb" DEFAULT '[]'::"jsonb", "p_default_impact_category" "text" DEFAULT NULL::"text", "p_package_result_hash" "text" DEFAULT NULL::"text", "p_audit" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_job private.worker_jobs%rowtype;
  v_receipt jsonb;
  v_result jsonb;
  v_package private.lcia_result_packages%rowtype;
  v_package_id uuid;
  v_suppress_default boolean;
  v_expected_default text;
begin
  if not coalesce(util.is_service_request(), false) then
    return api.lcia_result_error('service_role_required',403,'Service role is required');
  end if;
  select * into v_job from private.worker_jobs where id = p_build_worker_job_id for update;
  if v_job.id is null or v_job.job_kind <> 'lcia_result.package_build' then
    return api.lcia_result_error('build_worker_job_not_found',404,'Build Worker job not found');
  end if;
  if v_job.payload_schema_version = 'lcia_result.package_build.request.v3' then
    return api.lcia_result_error('build_worker_job_explicit_lease_required',409,'V3 private readiness requires the submitted lease token');
  end if;
  if v_job.status <> 'running' or v_job.lease_token is null
     or v_job.lease_expires_at is null or v_job.lease_expires_at <= clock_timestamp() then
    return api.lcia_result_error('build_worker_job_lease_invalid',409,'A current build lease is required');
  end if;
  v_receipt := private.lcia_registered_result_availability_v1(p_result_id,p_snapshot_id,false);
  if v_receipt is null or p_artifact_manifest->'lciaAvailability' is distinct from v_receipt then
    return api.lcia_result_error('lcia_package_availability_binding_invalid',409,'Current immutable category availability is required');
  end if;
  -- Match the preserved helper's complete-call normalization exactly. NULL
  -- for a partial callback remains an intentional absence, never a fallback.
  v_expected_default:=case when v_receipt->>'completeness'='complete' then coalesce(
    nullif(trim(coalesce(p_default_impact_category,'')),''),
    nullif(trim(coalesce(v_job.payload_json->>'default_impact_category','')),''))
    else p_default_impact_category end;
  -- Complete legacy calls must reach their original certificate diagnostics
  -- without firing the payload-admission trigger on a no-op UPDATE.
  v_suppress_default := v_receipt->>'completeness'<>'complete'
    and p_default_impact_category is null
    and nullif(btrim(coalesce(v_job.payload_json->>'default_impact_category','')),'') is not null;
  begin
    if v_suppress_default then
      update private.worker_jobs set payload_json=v_job.payload_json-'default_impact_category' where id=v_job.id;
    end if;
    v_result := private.lcia_package_mark_ready_before_category_availability_v1(
      p_build_worker_job_id,p_package_version,p_snapshot_id,p_result_id,
      p_latest_all_unit_result_id,p_result_artifact_ref,p_query_artifact_ref,
      p_artifact_manifest,p_available_impact_categories,p_default_impact_category,
      p_package_result_hash,p_audit);
    if v_suppress_default then
      update private.worker_jobs set payload_json=v_job.payload_json where id=v_job.id;
    end if;
    if coalesce((v_result->>'ok')::boolean,false) then
      v_package_id := (v_result->'data'->>'packageId')::uuid;
      select * into v_package from private.lcia_result_packages where id = v_package_id;
      if v_package.id is null or v_package.build_worker_job_id is distinct from v_job.id
         or v_package.snapshot_id is distinct from p_snapshot_id or v_package.result_id is distinct from p_result_id
         or v_package.artifact_manifest is distinct from p_artifact_manifest
         or v_package.available_impact_categories is distinct from p_available_impact_categories
         or v_package.default_impact_category is distinct from v_expected_default
         or not private.lcia_package_availability_valid_v1(v_package.id,false) then
        raise exception 'lcia_private_package_post_insert_validation_failed' using errcode = 'P5272';
      end if;
    end if;
    return v_result;
  exception when others then
    -- Subtransaction rollback restores the exact job payload/schema and removes
    -- any package inserted before a failed postcondition. Lease fields are untouched.
    return api.lcia_result_error('lcia_private_package_validation_failed',409,'Private result package could not be bound');
  end;
end
$$;

ALTER FUNCTION "private"."cmd_lcia_result_package_mark_ready"("p_build_worker_job_id" "uuid", "p_package_version" "text", "p_snapshot_id" "uuid", "p_result_id" "uuid", "p_latest_all_unit_result_id" "uuid", "p_result_artifact_ref" "jsonb", "p_query_artifact_ref" "jsonb", "p_artifact_manifest" "jsonb", "p_available_impact_categories" "jsonb", "p_default_impact_category" "text", "p_package_result_hash" "text", "p_audit" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."cmd_lcia_result_package_mark_ready"("p_build_worker_job_id" "uuid", "p_package_version" "text", "p_snapshot_id" "uuid", "p_result_id" "uuid", "p_latest_all_unit_result_id" "uuid", "p_result_artifact_ref" "jsonb", "p_query_artifact_ref" "jsonb", "p_artifact_manifest" "jsonb", "p_available_impact_categories" "jsonb", "p_default_impact_category" "text", "p_package_result_hash" "text", "p_audit" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."cmd_lcia_result_package_mark_ready"("p_build_worker_job_id" "uuid", "p_package_version" "text", "p_snapshot_id" "uuid", "p_result_id" "uuid", "p_latest_all_unit_result_id" "uuid", "p_result_artifact_ref" "jsonb", "p_query_artifact_ref" "jsonb", "p_artifact_manifest" "jsonb", "p_available_impact_categories" "jsonb", "p_default_impact_category" "text", "p_package_result_hash" "text", "p_audit" "jsonb") TO "service_role";

GRANT ALL ON FUNCTION "private"."cmd_lcia_result_package_mark_ready"("p_build_worker_job_id" "uuid", "p_package_version" "text", "p_snapshot_id" "uuid", "p_result_id" "uuid", "p_latest_all_unit_result_id" "uuid", "p_result_artifact_ref" "jsonb", "p_query_artifact_ref" "jsonb", "p_artifact_manifest" "jsonb", "p_available_impact_categories" "jsonb", "p_default_impact_category" "text", "p_package_result_hash" "text", "p_audit" "jsonb") TO "api_internal_executor";
