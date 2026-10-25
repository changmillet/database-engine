CREATE OR REPLACE FUNCTION "private"."svc_lcia_result_package_partial_mark_ready_v1"("p_build_worker_job_id" "uuid", "p_lease_token" "uuid", "p_package_version" "text", "p_snapshot_id" "uuid", "p_result_id" "uuid", "p_latest_all_unit_result_id" "uuid" DEFAULT NULL::"uuid", "p_result_artifact_ref" "jsonb" DEFAULT '{}'::"jsonb", "p_query_artifact_ref" "jsonb" DEFAULT '{}'::"jsonb", "p_artifact_manifest" "jsonb" DEFAULT '{}'::"jsonb", "p_available_impact_categories" "jsonb" DEFAULT '[]'::"jsonb", "p_default_impact_category" "text" DEFAULT NULL::"text", "p_package_result_hash" "text" DEFAULT NULL::"text", "p_audit" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_job private.worker_jobs%rowtype;
  v_package private.lcia_result_packages%rowtype;
  v_receipt jsonb;
  v_manifest jsonb;
  v_result jsonb;
  v_package_id uuid;
  v_reused boolean:=false;
begin
  if not coalesce(util.is_service_request(),false) then return api.lcia_result_error('service_role_required',403,'Service role is required'); end if;
  select * into v_job from private.worker_jobs where id=p_build_worker_job_id for update;
  if v_job.id is null or p_lease_token is null or v_job.lease_token is distinct from p_lease_token
     or v_job.status<>'running' or v_job.lease_expires_at is null or v_job.lease_expires_at<=clock_timestamp()
     or private.portal_lcia_projection_v3_job_binding_valid_v1(v_job.id,p_lease_token) is not true then
    return api.lcia_result_error('build_worker_job_lease_invalid',409,'A current submitted V3 build lease is required');
  end if;
  perform 1 from private.lca_results where id=p_result_id for share;
  perform 1 from private.lca_latest_all_unit_results where id=p_latest_all_unit_result_id for share;
  perform 1 from private.lca_network_snapshots where id=p_snapshot_id for share;
  v_receipt:=private.lcia_registered_result_availability_v1(p_result_id,p_snapshot_id,false);
  if v_receipt is null or v_receipt->>'completeness'='complete'
     or jsonb_typeof(p_artifact_manifest) is distinct from 'object'
     or p_artifact_manifest->'lciaAvailability' is distinct from v_receipt
     or p_artifact_manifest ? 'portalProjectionId' or p_artifact_manifest ? 'portalProjectionContentHash' then
    return api.lcia_result_error('lcia_package_availability_binding_invalid',409,'An exact private partial result is required');
  end if;
  if p_artifact_manifest ? 'privatePartialReadyRequestHash' and p_artifact_manifest->>'privatePartialReadyRequestHash' is distinct from private.lcia_partial_package_request_hash_v1(v_job) then
    return api.lcia_result_error('projection_package_binding_invalid',409,'Reserved private request binding does not match the locked job');
  end if;
  v_manifest:=(p_artifact_manifest-'privatePartialReadyRequestHash')||jsonb_build_object('privatePartialReadyRequestHash',private.lcia_partial_package_request_hash_v1(v_job));
  select * into v_package from private.lcia_result_packages where build_worker_job_id=v_job.id;
  if v_package.id is not null then
    v_reused:=true;
  else
    begin
      update private.worker_jobs set payload_schema_version='lcia_result.package_build.request.v2',
        payload_json=case when p_default_impact_category is null then v_job.payload_json-'default_impact_category' else v_job.payload_json end where id=v_job.id;
      v_result:=private.lcia_package_mark_ready_before_category_availability_v1(
        p_build_worker_job_id,p_package_version,p_snapshot_id,p_result_id,p_latest_all_unit_result_id,
        p_result_artifact_ref,p_query_artifact_ref,v_manifest,p_available_impact_categories,p_default_impact_category,p_package_result_hash,p_audit);
      update private.worker_jobs set payload_schema_version=v_job.payload_schema_version,payload_json=v_job.payload_json where id=v_job.id;
      if coalesce((v_result->>'ok')::boolean,false) is not true then return v_result; end if;
      v_package_id:=(v_result->'data'->>'packageId')::uuid;
      select * into v_package from private.lcia_result_packages where id=v_package_id;
      if v_package.id is null or v_package.build_worker_job_id is distinct from v_job.id
         or v_package.package_version is distinct from p_package_version or v_package.snapshot_id is distinct from p_snapshot_id
         or v_package.result_id is distinct from p_result_id or v_package.latest_all_unit_result_id is distinct from p_latest_all_unit_result_id
         or v_package.result_artifact_ref is distinct from p_result_artifact_ref or v_package.query_artifact_ref is distinct from p_query_artifact_ref
         or v_package.artifact_manifest is distinct from v_manifest or v_package.available_impact_categories is distinct from p_available_impact_categories
         or v_package.default_impact_category is distinct from p_default_impact_category or v_package.package_result_hash is distinct from p_package_result_hash
         or private.lcia_partial_package_binding_valid_v1(v_package.id,v_job.id) is not true
         or private.portal_lcia_projection_v3_job_binding_valid_v1(v_job.id,p_lease_token) is not true then
        raise exception 'lcia_private_package_post_insert_validation_failed' using errcode='P5272';
      end if;
    exception when others then
      return api.lcia_result_error('lcia_private_package_validation_failed',409,'Private package binding failed; no package was committed');
    end;
  end if;
  if v_package.package_version is distinct from p_package_version or v_package.snapshot_id is distinct from p_snapshot_id
     or v_package.result_id is distinct from p_result_id or v_package.latest_all_unit_result_id is distinct from p_latest_all_unit_result_id
     or v_package.result_artifact_ref is distinct from p_result_artifact_ref or v_package.query_artifact_ref is distinct from p_query_artifact_ref
     or v_package.artifact_manifest is distinct from v_manifest or v_package.available_impact_categories is distinct from p_available_impact_categories
     or v_package.default_impact_category is distinct from p_default_impact_category or v_package.package_result_hash is distinct from p_package_result_hash
     or private.lcia_partial_package_binding_valid_v1(v_package.id,v_job.id) is not true then
    return api.lcia_result_error('projection_package_binding_invalid',409,'Committed package differs from the exact submitted request');
  end if;
  return jsonb_build_object('ok',true,'reused',v_reused,'data',jsonb_build_object(
    'packageId',v_package.id,'packageVersion',v_package.package_version,'status',v_package.status,
    'buildWorkerJobId',v_package.build_worker_job_id,'includedInputCount',v_package.included_input_count,
    'lciaAvailability',v_package.artifact_manifest->'lciaAvailability'));
end
$$;

ALTER FUNCTION "private"."svc_lcia_result_package_partial_mark_ready_v1"("p_build_worker_job_id" "uuid", "p_lease_token" "uuid", "p_package_version" "text", "p_snapshot_id" "uuid", "p_result_id" "uuid", "p_latest_all_unit_result_id" "uuid", "p_result_artifact_ref" "jsonb", "p_query_artifact_ref" "jsonb", "p_artifact_manifest" "jsonb", "p_available_impact_categories" "jsonb", "p_default_impact_category" "text", "p_package_result_hash" "text", "p_audit" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."svc_lcia_result_package_partial_mark_ready_v1"("p_build_worker_job_id" "uuid", "p_lease_token" "uuid", "p_package_version" "text", "p_snapshot_id" "uuid", "p_result_id" "uuid", "p_latest_all_unit_result_id" "uuid", "p_result_artifact_ref" "jsonb", "p_query_artifact_ref" "jsonb", "p_artifact_manifest" "jsonb", "p_available_impact_categories" "jsonb", "p_default_impact_category" "text", "p_package_result_hash" "text", "p_audit" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."svc_lcia_result_package_partial_mark_ready_v1"("p_build_worker_job_id" "uuid", "p_lease_token" "uuid", "p_package_version" "text", "p_snapshot_id" "uuid", "p_result_id" "uuid", "p_latest_all_unit_result_id" "uuid", "p_result_artifact_ref" "jsonb", "p_query_artifact_ref" "jsonb", "p_artifact_manifest" "jsonb", "p_available_impact_categories" "jsonb", "p_default_impact_category" "text", "p_package_result_hash" "text", "p_audit" "jsonb") TO "service_role";
