CREATE OR REPLACE FUNCTION "private"."svc_lcia_result_package_ready_readback_v1"("p_build_worker_job_id" "uuid", "p_current_lease_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_job private.worker_jobs%rowtype;
  v_package private.lcia_result_packages%rowtype;
begin
  if not coalesce(util.is_service_request(),false) then return api.lcia_result_error('service_role_required',403,'Service role is required'); end if;
  select * into v_job from private.worker_jobs where id=p_build_worker_job_id for update;
  if v_job.id is null or v_job.lease_token is distinct from p_current_lease_token
     or p_current_lease_token is null or v_job.status<>'running'
     or v_job.lease_expires_at is null or v_job.lease_expires_at<=clock_timestamp()
     or private.portal_lcia_projection_v3_job_binding_valid_v1(v_job.id,p_current_lease_token) is not true then
    return api.lcia_result_error('projection_lease_invalid',409,'A current submitted build lease is required');
  end if;
  select * into v_package from private.lcia_result_packages where build_worker_job_id=v_job.id;
  if v_package.id is null then return api.lcia_result_error('projection_package_not_found',404,'No committed package exists'); end if;
  perform 1 from private.lca_results where id=v_package.result_id for share;
  perform 1 from private.lca_latest_all_unit_results where id=v_package.latest_all_unit_result_id for share;
  perform 1 from private.lca_network_snapshots where id=v_package.snapshot_id for share;
  if v_package.artifact_manifest ? 'portalProjectionId' then
    return private.svc_portal_lcia_projection_package_ready_readback_v1(v_job.id,p_current_lease_token);
  end if;
  if private.lcia_partial_package_binding_valid_v1(v_package.id,v_job.id) is not true then
    return api.lcia_result_error('projection_package_binding_invalid',409,'Committed private partial package binding has changed');
  end if;
  return jsonb_build_object('ok',true,'reused',true,'data',jsonb_build_object(
    'packageId',v_package.id,'packageVersion',v_package.package_version,'status',v_package.status,
    'buildWorkerJobId',v_package.build_worker_job_id,'includedInputCount',v_package.included_input_count,
    'lciaAvailability',v_package.artifact_manifest->'lciaAvailability'));
end
$$;

ALTER FUNCTION "private"."svc_lcia_result_package_ready_readback_v1"("p_build_worker_job_id" "uuid", "p_current_lease_token" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."svc_lcia_result_package_ready_readback_v1"("p_build_worker_job_id" "uuid", "p_current_lease_token" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."svc_lcia_result_package_ready_readback_v1"("p_build_worker_job_id" "uuid", "p_current_lease_token" "uuid") TO "service_role";
