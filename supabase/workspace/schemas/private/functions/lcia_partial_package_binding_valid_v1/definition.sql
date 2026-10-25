CREATE OR REPLACE FUNCTION "private"."lcia_partial_package_binding_valid_v1"("p_package_id" "uuid", "p_build_worker_job_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_package private.lcia_result_packages%rowtype;
  v_job private.worker_jobs%rowtype;
  v_result private.lca_results%rowtype;
  v_latest private.lca_latest_all_unit_results%rowtype;
  v_build_id uuid;
  v_closure_id uuid;
  v_resolved_at timestamptz;
  v_eligible integer;
  v_included integer;
  v_receipt jsonb;
  v_expected_result jsonb;
  v_expected_query jsonb;
  v_default text;
  v_requested text;
  v_available jsonb;
  v_scope_evidence jsonb;
begin
  select * into v_package from private.lcia_result_packages where id=p_package_id and build_worker_job_id=p_build_worker_job_id;
  select * into v_job from private.worker_jobs where id=p_build_worker_job_id;
  if v_package.id is null or v_job.id is null
     or v_job.job_kind <> 'lcia_result.package_build'
     or v_job.subject_type <> 'lcia_result_build'
     or v_job.payload_schema_version <> 'lcia_result.package_build.request.v3'
     or v_package.status <> 'preview_ready'
     or v_package.artifact_manifest ? 'portalProjectionId'
     or v_package.artifact_manifest ? 'portalProjectionContentHash'
     or v_package.artifact_manifest->>'privatePartialReadyRequestHash'
          is distinct from private.lcia_partial_package_request_hash_v1(v_job)
     or not private.lcia_package_availability_valid_v1(v_package.id,false) then return false; end if;
  v_receipt:=v_package.artifact_manifest->'lciaAvailability';
  if v_receipt->>'completeness'='complete' then return false; end if;
  begin
    v_build_id:=nullif(v_job.payload_json->>'build_id','')::uuid;
    v_closure_id:=nullif(v_job.payload_json->>'closure_check_id','')::uuid;
    v_resolved_at:=nullif(v_job.payload_json->>'eligibility_resolved_at','')::timestamptz;
    v_eligible:=coalesce((v_job.payload_json->>'eligible_input_count')::integer,0);
    v_included:=coalesce((v_job.payload_json->>'included_input_count')::integer,0);
  exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then return false;
  end;
  if v_build_id is null or v_closure_id is null or v_resolved_at is null then return false; end if;
  select * into v_result from private.lca_results where id=v_package.result_id;
  select * into v_latest from private.lca_latest_all_unit_results where id=v_package.latest_all_unit_result_id;
  if v_result.id is null or v_latest.id is null or v_latest.status<>'ready'
     or v_result.job_id is distinct from v_build_id
     or v_result.worker_job_id is distinct from v_job.id
     or v_result.snapshot_id is distinct from v_package.snapshot_id
     or v_latest.job_id is distinct from v_build_id
     or v_latest.worker_job_id is distinct from v_job.id
     or v_latest.snapshot_id is distinct from v_package.snapshot_id
     or v_latest.result_id is distinct from v_result.id
     or v_latest.query_artifact_format <> 'all-unit-query:v3' then return false; end if;
  v_expected_result:=jsonb_build_object('artifactUrl',v_result.artifact_url,'artifactSha256',v_result.artifact_sha256,'artifactByteSize',v_result.artifact_byte_size,'artifactFormat',v_result.artifact_format);
  v_expected_query:=jsonb_build_object('artifactUrl',v_latest.query_artifact_url,'artifactSha256',v_latest.query_artifact_sha256,'artifactByteSize',v_latest.query_artifact_byte_size,'artifactFormat',v_latest.query_artifact_format);
  select coalesce(jsonb_agg(c->'method_id' order by ordinality),'[]'::jsonb) into v_available
    from jsonb_array_elements(v_receipt->'categories') with ordinality as categories(c,ordinality) where c->>'status'='available';
  v_requested:=nullif(btrim(coalesce(v_job.payload_json->>'default_impact_category','')),'');
  v_default:=case when v_requested is null then v_available->>0
    when v_requested ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then case when v_available ? v_requested then v_requested else null end
    -- A legacy exact impact-key alias is resolved by the Worker against its
    -- frozen axis; membership plus the immutable request digest binds that choice.
    else v_package.default_impact_category end;
  v_scope_evidence:=jsonb_build_object(
    'closureCheckId',v_closure_id,'certificateHash',v_job.payload_json->>'closure_certificate_hash',
    'effectiveScopeHash',v_job.payload_json->>'effective_scope_hash','dataSnapshotToken',v_job.payload_json->>'data_snapshot_token',
    'snapshotId',v_job.payload_json->>'snapshot_id','snapshotHash',v_job.payload_json->>'snapshot_hash',
    'closureBundleHash',v_job.payload_json->>'closure_bundle_hash','closureBundleArtifactId',v_job.payload_json->>'closure_bundle_artifact_id',
    'reportArtifactManifestHash',v_job.payload_json->>'report_artifact_manifest_hash');
  return coalesce(v_package.build_id=v_build_id and v_job.subject_id=v_build_id
    and v_package.package_version='lcia-result-'||v_build_id::text
    and v_package.coverage_mode is not distinct from (v_job.payload_json->>'coverage_mode')
    and v_package.input_status_filter is not distinct from coalesce(v_job.payload_json->'input_status_filter','{"state_code":{"between":[100,199]}}'::jsonb)
    and v_package.eligibility_definition is not distinct from coalesce(v_job.payload_json->'eligibility_definition','{}'::jsonb)
    and v_package.eligibility_resolved_at is not distinct from v_resolved_at
    and v_package.eligible_input_count=v_eligible and v_package.included_input_count=v_included
    and v_package.input_manifest_hash is not distinct from (v_job.payload_json->>'input_manifest_hash')
    and v_package.input_manifest is not distinct from coalesce(v_job.payload_json->'input_manifest','{}'::jsonb)
    and v_package.snapshot_id::text is not distinct from (v_job.payload_json->>'snapshot_id')
    and v_package.lcia_method_set is not distinct from coalesce(v_job.payload_json->'lcia_method_set','[]'::jsonb)
    and v_package.postprocess_manifest is not distinct from coalesce(v_job.payload_json->'postprocess_manifest','{"postprocess_mode":"skipped"}'::jsonb)
    and v_package.default_impact_category is not distinct from v_default
    and v_package.closure_check_id is not distinct from v_closure_id
    and v_package.closure_certificate_hash is not distinct from (v_job.payload_json->>'closure_certificate_hash')
    and v_package.closure_snapshot_hash is not distinct from (v_job.payload_json->>'snapshot_hash')
    and v_package.created_by is not distinct from v_job.requested_by
    and v_package.result_artifact_ref is not distinct from v_expected_result
    and v_package.query_artifact_ref is not distinct from v_expected_query
    and v_package.artifact_manifest->'queryArtifact' is not distinct from v_expected_query
    and v_package.artifact_manifest->>'inputManifestHash' is not distinct from v_package.input_manifest_hash
    and v_package.artifact_manifest->'scopeClosureEvidence' is not distinct from v_scope_evidence,false);
end
$_$;

ALTER FUNCTION "private"."lcia_partial_package_binding_valid_v1"("p_package_id" "uuid", "p_build_worker_job_id" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."lcia_partial_package_binding_valid_v1"("p_package_id" "uuid", "p_build_worker_job_id" "uuid") FROM PUBLIC;
