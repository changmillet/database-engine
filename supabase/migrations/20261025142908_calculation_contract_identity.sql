-- Calculation implementations own their descriptor bytes. Storage compares opaque hashes.
-- No algorithm version is selected by this migration. Activation is an explicit rollout step.
create table private.lca_calculation_contracts (
  fingerprint text primary key check (fingerprint ~ '^[0-9a-f]{64}$'),
  descriptor text not null check (octet_length(descriptor) between 2 and 16384),
  created_at timestamptz not null default now(),
  constraint lca_calculation_descriptor_hash check (
    fingerprint = encode(extensions.digest(descriptor, 'sha256'), 'hex')),
  constraint lca_calculation_descriptor_object check (jsonb_typeof(descriptor::jsonb) = 'object')
);
create table private.lca_active_calculation_contract (
  singleton boolean primary key default true check (singleton),
  fingerprint text references private.lca_calculation_contracts(fingerprint),
  updated_at timestamptz not null default now()
);
insert into private.lca_active_calculation_contract(singleton) values (true);
alter table private.lca_calculation_contracts enable row level security;
alter table private.lca_active_calculation_contract enable row level security;
revoke all on private.lca_calculation_contracts, private.lca_active_calculation_contract from public, anon, authenticated, service_role;

create function private.svc_lca_calculation_contract_activate(p_descriptor text, p_expected_fingerprint text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_current text; v_fingerprint text;
begin
  if not coalesce(util.is_service_request(), false) then
    return jsonb_build_object('ok', false, 'code', 'SERVICE_ROLE_REQUIRED');
  end if;
  if p_descriptor is null or octet_length(p_descriptor) not between 2 and 16384
     or jsonb_typeof(p_descriptor::jsonb) <> 'object' then
    return jsonb_build_object('ok', false, 'code', 'INVALID_CALCULATION_DESCRIPTOR');
  end if;
  select fingerprint into v_current from private.lca_active_calculation_contract where singleton for update;
  if v_current is distinct from p_expected_fingerprint then
    return jsonb_build_object('ok', false, 'code', 'CALCULATION_ACTIVATION_CONFLICT', 'currentFingerprint', v_current);
  end if;
  v_fingerprint := encode(extensions.digest(p_descriptor, 'sha256'), 'hex');
  insert into private.lca_calculation_contracts(fingerprint, descriptor) values (v_fingerprint, p_descriptor)
    on conflict (fingerprint) do nothing;
  if not exists (select 1 from private.lca_calculation_contracts where fingerprint=v_fingerprint and descriptor=p_descriptor) then
    raise exception 'calculation_contract_identity_conflict';
  end if;
  update private.lca_active_calculation_contract set fingerprint=v_fingerprint, updated_at=now() where singleton;
  return jsonb_build_object('ok', true, 'fingerprint', v_fingerprint);
exception when invalid_text_representation then
  return jsonb_build_object('ok', false, 'code', 'INVALID_CALCULATION_DESCRIPTOR');
end;
$$;
revoke all on function private.svc_lca_calculation_contract_activate(text,text) from public, anon, authenticated;
grant execute on function private.svc_lca_calculation_contract_activate(text,text) to service_role;

create function private.lca_calculation_contract_is_current(p_fingerprint text)
returns boolean language sql stable security definer set search_path = '' as $$
  select fingerprint is null or fingerprint is not distinct from p_fingerprint
  from private.lca_active_calculation_contract where singleton;
$$;
revoke all on function private.lca_calculation_contract_is_current(text) from public, anon, authenticated;
grant execute on function private.lca_calculation_contract_is_current(text) to service_role, api_internal_executor;

alter table private.lcia_scope_closure_checks
  add column calculation_fingerprint text references private.lca_calculation_contracts(fingerprint),
  add column request_payload_hash text;
alter table private.lcia_scope_closure_scan_executions
  add column calculation_fingerprint text references private.lca_calculation_contracts(fingerprint);
-- Nonunique because pre-contract histories may contain repeated actor/token pairs.
create index lcia_scope_closure_checks_actor_token_idx on private.lcia_scope_closure_checks(requested_by, request_idempotency_token, created_at, id);
create index lcia_scope_closure_checks_calculation_idx on private.lcia_scope_closure_checks(calculation_fingerprint) where calculation_fingerprint is not null;
create index lcia_scope_closure_scan_calculation_idx on private.lcia_scope_closure_scan_executions(calculation_fingerprint) where calculation_fingerprint is not null;

CREATE OR REPLACE FUNCTION "api"."cmd_lcia_scope_closure_check_request_v2"("p_requested_scope" "jsonb", "p_request_idempotency_token" "text", "p_audit" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'api', 'private', 'public', 'util', 'extensions', 'pg_temp'
    SET "statement_timeout" TO '60s'
    AS $$
declare
  v_actor uuid := auth.uid();
  v_calculation_fingerprint text;
  v_payload_hash text := private.lcia_scope_closure_sha256(p_requested_scope);
  v_scope jsonb;
  v_policy jsonb;
  v_requested_scope_hash text;
  v_policy_fingerprint text;
  v_expected_validator text;
  v_snapshot_manifest jsonb;
  v_snapshot_token text;
  v_request_fingerprint text;
  v_request_key text;
  v_result jsonb;
  v_check private.lcia_scope_closure_checks%rowtype;
  v_job private.worker_jobs%rowtype;
  v_execution private.lcia_scope_closure_scan_executions%rowtype;
  v_publication private.lca_release_publications%rowtype;
  v_run private.lca_release_runs%rowtype;
  v_dataset_manifest jsonb;
  v_candidate_manifest_hash text;
  v_publication_epoch bigint := 0;
  v_missing_root_count integer;
begin
  if v_actor is null then
    return api.lcia_scope_closure_error(
      'auth_required', 401, 'Authentication required'
    );
  end if;
  if not api.lcia_scope_closure_is_manager() then
    return api.lcia_scope_closure_error(
      'not_data_product_manager', 403, 'Data product manager role is required'
    );
  end if;
  if coalesce(nullif(trim(p_request_idempotency_token), ''), '') = '' then
    return api.lcia_scope_closure_error(
      'invalid_closure_request', 400, 'Idempotency token is required'
    );
  end if;

  -- A retry is the original operation, even after a new calculation contract activates.
  perform pg_advisory_xact_lock(hashtextextended(v_actor::text || ':' || trim(p_request_idempotency_token), 873));
  select * into v_check from private.lcia_scope_closure_checks
    where requested_by=v_actor and request_idempotency_token=trim(p_request_idempotency_token)
    order by created_at, id limit 1 for update;
  if v_check.id is not null then
    if v_check.request_payload_hash is not null and v_check.request_payload_hash is distinct from v_payload_hash then
      return api.lcia_scope_closure_error('idempotency_payload_conflict',409,'Idempotency token belongs to another request');
    end if;
    select * into v_job from private.worker_jobs where id=v_check.worker_job_id;
    return jsonb_build_object('ok',true,'data',jsonb_build_object(
      'closureCheckId',v_check.id,'requestedScopeHash',v_check.requested_scope_hash,
      'policyFingerprint',v_check.policy_fingerprint,'dataSnapshotToken',v_check.data_snapshot_token,
      'scanExecutionId',v_check.scan_execution_id,'calculationFingerprint',v_check.calculation_fingerprint,
      'workerJob',private.worker_job_payload(v_job,false),'reused',true));
  end if;
  select fingerprint into v_calculation_fingerprint
    from private.lca_active_calculation_contract where singleton for share;

  v_scope := private.lcia_scope_closure_normalize_request(p_requested_scope);

  if v_scope->>'eligibilityPredicateVersion' = 'current-public-release-manifest:v2' then
    select *
    into v_publication
    from private.lca_release_publications
    where is_current = true and status = 'current'
    order by published_at desc
    limit 1;

    if v_publication.id is null then
      return api.lcia_scope_closure_error(
        'closure_snapshot_source_changed',
        409,
        'The current release changed while the closure snapshot was being frozen; retry the check'
      );
    end if;
    select *
    into v_run
    from private.lca_release_runs
    where id = v_publication.release_run_id;
    if v_run.id is null or v_run.release_manifest_hash is null then
      return api.lcia_scope_closure_error(
        'closure_evidence_unavailable',
        503,
        'Current public release manifest is unavailable'
      );
    end if;
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'datasetType', d.dataset_type,
        'datasetId', d.dataset_uuid,
        'datasetVersion', d.dataset_version,
        'role', d.dataset_role,
        'sourceProcessId', d.source_process_uuid,
        'sourceProcessVersion', d.source_process_version,
        'versionSignificantHash', d.version_significant_hash,
        'semanticHash', d.semantic_hash,
        'canonicalContentHash', d.canonical_content_hash
      )
      order by d.dataset_type, d.dataset_uuid, d.dataset_version, d.dataset_role
    ), '[]'::jsonb)
    into v_dataset_manifest
    from private.lca_release_dataset_versions d
    where d.release_run_id = v_run.id;

    if jsonb_array_length(v_dataset_manifest) = 0 then
      return api.lcia_scope_closure_error(
        'closure_evidence_unavailable',
        503,
        'Current public release dataset manifest is empty'
      );
    end if;

    v_snapshot_manifest := jsonb_build_object(
      'schemaVersion', 'lcia.scope-closure-data-snapshot.v2',
      'requestedScope', v_scope,
      'currentPublicRelease', jsonb_build_object(
        'publicationId', v_publication.id,
        'releaseRunId', v_run.id,
        'releaseVersion', v_run.release_version,
        'publishedAt', v_publication.published_at,
        'releaseManifestHash', v_run.release_manifest_hash
      ),
      'datasets', v_dataset_manifest
    );
    v_publication_epoch := extract(epoch from v_publication.published_at)::bigint;
  else
    if v_scope->>'certificateFreshnessPolicy' = 'current-membership-required-v1' then
      return api.lcia_scope_closure_error(
        'current_release_required',
        409,
        'Current-membership freshness requires a current formal release'
      );
    end if;

    v_dataset_manifest :=
      private.lcia_scope_closure_candidate_dataset_manifest();
    if jsonb_array_length(v_dataset_manifest) = 0 then
      return api.lcia_scope_closure_error(
        'closure_evidence_unavailable',
        503,
        'Candidate public-state dataset manifest is empty'
      );
    end if;

    with roots as (
      select 'processes'::text as dataset_type,
        (item.value->>'id')::uuid as dataset_id,
        item.value->>'version' as dataset_version
      from jsonb_array_elements(v_scope->'processes') item(value)
      union all
      select 'lciamethods',
        (item.value->>'id')::uuid,
        item.value->>'version'
      from jsonb_array_elements(v_scope->'lciaMethods') item(value)
    ),
    frozen as (
      select item.value->>'datasetType' as dataset_type,
        (item.value->>'datasetId')::uuid as dataset_id,
        item.value->>'datasetVersion' as dataset_version
      from jsonb_array_elements(v_dataset_manifest) item(value)
    )
    select count(*)
    into v_missing_root_count
    from roots r
    left join frozen f using (dataset_type, dataset_id, dataset_version)
    where f.dataset_id is null;

    if v_missing_root_count <> 0 then
      return api.lcia_scope_closure_error(
        'closure_snapshot_source_changed',
        409,
        'Candidate data changed while the closure snapshot was being frozen; retry the check'
      );
    end if;

    v_candidate_manifest_hash := private.lcia_scope_closure_sha256(
      jsonb_build_object(
        'eligibilityPredicateVersion',
          v_scope->>'eligibilityPredicateVersion',
        'datasets', v_dataset_manifest
      )
    );
    v_snapshot_manifest := jsonb_build_object(
      'schemaVersion', 'lcia.scope-closure-data-snapshot.v2',
      'requestedScope', v_scope,
      -- Required only for deployed Worker v2 compatibility.  candidateData
      -- below is the authoritative source description.
      'currentPublicRelease', jsonb_build_object(
        'publicationId', '00000000-0000-0000-0000-000000000000',
        'releaseRunId', '00000000-0000-0000-0000-000000000000',
        'releaseVersion', 'candidate-public-state-v1',
        'publishedAt', '1970-01-01T00:00:00Z',
        'releaseManifestHash', v_candidate_manifest_hash
      ),
      'candidateData', jsonb_build_object(
        'sourceKind', 'candidate-public-state',
        'eligibilityPredicateVersion',
          v_scope->>'eligibilityPredicateVersion',
        'datasetManifestHash', v_candidate_manifest_hash,
        'workerV2CompatibilityProjection', true
      ),
      'datasets', v_dataset_manifest
    );
  end if;

  v_snapshot_token := private.lcia_scope_closure_sha256(v_snapshot_manifest);
  v_requested_scope_hash := private.lcia_scope_closure_sha256(v_scope);
  v_policy := jsonb_build_object(
    'scopePolicy', v_scope - 'processes' - 'lciaMethods' - 'processManifestHash',
    'visibilityScope', 'data_product_manager.v1'
  );
  v_policy_fingerprint := private.lcia_scope_closure_sha256(v_policy);
  select expected_validator_scanner_fingerprint
  into v_expected_validator
  from private.lcia_scope_closure_config
  where singleton;
  if v_expected_validator is null then
    return api.lcia_scope_closure_error(
      'closure_evidence_unavailable',
      503,
      'Closure validator configuration is unavailable'
    );
  end if;

  v_request_fingerprint := encode(extensions.digest(
    v_requested_scope_hash || '|' || v_policy_fingerprint || '|'
      || v_expected_validator || '|' || v_snapshot_token
      || case when v_calculation_fingerprint is null then '' else '|calculation:' || v_calculation_fingerprint end,
    'sha256'
  ), 'hex');
  v_request_key := encode(extensions.digest(
    v_actor::text || '|' || trim(p_request_idempotency_token) || '|'
      || v_request_fingerprint,
    'sha256'
  ), 'hex');

  select *
  into v_check
  from private.lcia_scope_closure_checks
  where requested_by = v_actor and request_key = v_request_key
  for update;
  if v_check.id is not null then
    select * into v_job from private.worker_jobs where id = v_check.worker_job_id;
    return jsonb_build_object(
      'ok', true,
      'data', jsonb_build_object(
        'closureCheckId', v_check.id,
        'requestedScopeHash', v_check.requested_scope_hash,
        'policyFingerprint', v_check.policy_fingerprint,
        'dataSnapshotToken', v_check.data_snapshot_token,
        'scanExecutionId', v_check.scan_execution_id,
        'workerJob', private.worker_job_payload(v_job, false),
        'reused', true
      )
    );
  end if;

  v_result := private.cmd_lcia_scope_closure_check_request_v2_untracked(
    p_requested_scope,
    p_request_idempotency_token,
    p_audit
  );
  if coalesce((v_result->>'ok')::boolean, false) is not true then
    return v_result;
  end if;
  select *
  into v_check
  from private.lcia_scope_closure_checks
  where id = nullif(v_result->'data'->>'closureCheckId', '')::uuid
  for update;
  if v_check.id is null then
    return api.lcia_scope_closure_error(
      'closure_check_not_found', 404, 'Closure check not found'
    );
  end if;
  if coalesce((v_result->'data'->>'reused')::boolean, false)
     and v_check.request_key <> v_request_key
     and v_check.data_snapshot_token <> v_snapshot_token then
    return api.lcia_scope_closure_error(
      'idempotency_token_bound_to_different_snapshot',
      409,
      'Idempotency token is already bound to a different data snapshot'
    );
  end if;

  insert into private.lcia_scope_closure_data_snapshots(
    data_snapshot_token,
    root_manifest,
    root_manifest_hash,
    publication_epoch
  ) values (
    v_snapshot_token,
    v_snapshot_manifest,
    private.lcia_scope_closure_sha256(v_snapshot_manifest),
    v_publication_epoch
  )
  on conflict (data_snapshot_token) do nothing;

  update private.lcia_scope_closure_checks
  set data_snapshot_token = v_snapshot_token,
      requested_scope_manifest = v_scope,
      requested_scope_hash = v_requested_scope_hash,
      policy_fingerprint = v_policy_fingerprint,
      request_fingerprint = v_request_fingerprint,
      request_key = v_request_key,
      calculation_fingerprint = v_calculation_fingerprint,
      request_payload_hash = v_payload_hash,
      updated_at = now()
  where id = v_check.id
  returning * into v_check;

  perform pg_advisory_xact_lock(hashtextextended(v_request_fingerprint, 873));
  select *
  into v_execution
  from private.lcia_scope_closure_scan_executions
  where request_fingerprint = v_request_fingerprint
  for update;
  if v_execution.id is null then
    insert into private.lcia_scope_closure_scan_executions(
      request_fingerprint,
      requested_scope_hash,
      policy_fingerprint,
      data_snapshot_token,
      validator_scanner_fingerprint,
      calculation_fingerprint
    ) values (
      v_request_fingerprint,
      v_requested_scope_hash,
      v_policy_fingerprint,
      v_snapshot_token,
      v_expected_validator,
      v_calculation_fingerprint
    )
    returning * into v_execution;
  end if;

  update private.lcia_scope_closure_checks
  set scan_execution_id = v_execution.id,
      updated_at = now()
  where id = v_check.id
  returning * into v_check;

  update private.worker_jobs
  set request_hash = v_request_fingerprint,
      concurrency_key = v_request_key,
      payload_json = payload_json || jsonb_build_object(
        'coverage_mode', v_scope->>'coverageMode',
        'input_manifest', jsonb_build_object(
          'predicateVersion', v_scope->>'eligibilityPredicateVersion',
          'selectionMode', 'closure_certificate',
          'processes', v_scope->'processes'
        ),
        'input_manifest_hash',
          private.lcia_scope_closure_sha256(
            jsonb_build_object('processes', v_scope->'processes')
          ),
        'lcia_method_set', v_scope->'lciaMethods',
        'request_fingerprint', v_request_fingerprint,
        'calculation_fingerprint', v_calculation_fingerprint,
        'scan_execution_id', v_execution.id,
        'data_snapshot_token', v_snapshot_token
      ),
      updated_at = now()
  where id = v_check.worker_job_id
  returning * into v_job;

  return jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'closureCheckId', v_check.id,
      'requestedScopeHash', v_check.requested_scope_hash,
      'policyFingerprint', v_check.policy_fingerprint,
      'dataSnapshotToken', v_snapshot_token,
      'scanExecutionId', v_execution.id,
      'calculationFingerprint', v_calculation_fingerprint,
      'workerJob', private.worker_job_payload(v_job, false),
      'reused', false
    )
  );
exception
  when sqlstate '22023' then
    return api.lcia_scope_closure_error(
      'invalid_closure_scope', 400, sqlerrm
    );
end;
$$;

ALTER FUNCTION "api"."cmd_lcia_scope_closure_check_request_v2"("p_requested_scope" "jsonb", "p_request_idempotency_token" "text", "p_audit" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."cmd_lcia_scope_closure_check_request_v2"("p_requested_scope" "jsonb", "p_request_idempotency_token" "text", "p_audit" "jsonb") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."cmd_lcia_scope_closure_check_request_v2"("p_requested_scope" "jsonb", "p_request_idempotency_token" "text", "p_audit" "jsonb") TO "api_internal_executor";

GRANT ALL ON FUNCTION "api"."cmd_lcia_scope_closure_check_request_v2"("p_requested_scope" "jsonb", "p_request_idempotency_token" "text", "p_audit" "jsonb") TO "authenticated";

CREATE OR REPLACE FUNCTION "private"."svc_lcia_scope_closure_check_get_worker_input"("p_closure_check_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'private', 'api', 'public', 'util', 'extensions', 'pg_temp'
    AS $$
declare
  v_check private.lcia_scope_closure_checks%rowtype;
  v_data_snapshot private.lcia_scope_closure_data_snapshots%rowtype;
  v_execution private.lcia_scope_closure_scan_executions%rowtype;
begin
  if not coalesce(util.is_service_request(), false) then
    return api.lcia_scope_closure_error('service_role_required', 403, 'Service role is required');
  end if;
  select * into v_check
  from private.lcia_scope_closure_checks
  where id = p_closure_check_id;
  select * into v_data_snapshot
  from private.lcia_scope_closure_data_snapshots
  where data_snapshot_token = v_check.data_snapshot_token;
  select * into v_execution
  from private.lcia_scope_closure_scan_executions
  where id = v_check.scan_execution_id;
  if v_check.id is null
     or v_check.requested_scope_manifest is null
     or v_data_snapshot.data_snapshot_token is null
     or v_execution.id is null
     or v_execution.numerical_snapshot_id is null then
    return api.lcia_scope_closure_error('closure_check_not_found', 404, 'Closure check or preallocated numerical snapshot not found');
  end if;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'closureCheckId', v_check.id,
    'scanExecutionId', v_check.scan_execution_id,
    'numericalSnapshotId', v_execution.numerical_snapshot_id,
    'requestedScope', v_check.requested_scope_manifest,
    'requestedScopeHash', v_check.requested_scope_hash,
    'policyFingerprint', v_check.policy_fingerprint,
    'dataSnapshotToken', v_check.data_snapshot_token,
    'dataSnapshotManifest', v_data_snapshot.root_manifest,
    'dataSnapshotManifestHash', v_data_snapshot.root_manifest_hash,
    'publicationEpoch', v_data_snapshot.publication_epoch,
    'expectedValidatorScannerFingerprint', v_check.expected_validator_scanner_fingerprint,
    'requestFingerprint', v_check.request_fingerprint
  ) || case when v_check.calculation_fingerprint is null then '{}'::jsonb
    else jsonb_build_object('calculationFingerprint', v_check.calculation_fingerprint) end);
end;
$$;

ALTER FUNCTION "private"."svc_lcia_scope_closure_check_get_worker_input"("p_closure_check_id" "uuid") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."svc_lcia_scope_closure_check_get_worker_input"("p_closure_check_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."svc_lcia_scope_closure_check_get_worker_input"("p_closure_check_id" "uuid") TO "service_role";

GRANT ALL ON FUNCTION "private"."svc_lcia_scope_closure_check_get_worker_input"("p_closure_check_id" "uuid") TO "api_internal_executor";

CREATE OR REPLACE FUNCTION "api"."svc_lca_snapshot_candidates"("p_scope" "text", "p_snapshot_id" "uuid" DEFAULT NULL::"uuid", "p_process_filter_contains" "jsonb" DEFAULT NULL::"jsonb", "p_limit" integer DEFAULT 100) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_scope text := lower(btrim(coalesce(p_scope, '')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 100));
  v_rows jsonb;
  v_calculation_fingerprint text;
begin
  if v_scope not in ('full_library', 'data_product') then
    return jsonb_build_object('ok', false, 'code', 'INVALID_LCA_SCOPE', 'status', 400);
  end if;

  select fingerprint into v_calculation_fingerprint from private.lca_active_calculation_contract where singleton;

  with candidates as (
    select
      snapshot.id,
      snapshot.scope,
      snapshot.process_filter,
      (v_calculation_fingerprint is null or coalesce(snapshot.process_filter->>'calculation_fingerprint' = v_calculation_fingerprint, false)) as calculation_current,
      snapshot.source_hash,
      snapshot.created_at,
      artifact.id as artifact_id,
      artifact.artifact_url,
      artifact.artifact_sha256,
      artifact.artifact_byte_size,
      artifact.artifact_format,
      artifact.process_count,
      artifact.flow_count,
      artifact.impact_count,
      artifact.snapshot_index_sha256,
      artifact.snapshot_build_contract_hash,
      artifact.effective_scope_hash,
      artifact.data_snapshot_token,
      artifact.closure_bundle_hash,
      active.snapshot_id is not null as is_active
    from private.lca_network_snapshots as snapshot
    join lateral (
      select candidate_artifact.*
      from private.lca_snapshot_artifacts as candidate_artifact
      where candidate_artifact.snapshot_id = snapshot.id
        and candidate_artifact.status = 'ready'
      order by candidate_artifact.created_at desc, candidate_artifact.id
      limit 1
    ) as artifact on true
    left join private.lca_active_snapshots as active
      on active.scope = v_scope and active.snapshot_id = snapshot.id
    where snapshot.status = 'ready'
      and (
        (p_snapshot_id is not null and snapshot.id = p_snapshot_id)
        or (
          p_snapshot_id is null
          and snapshot.scope in (v_scope, 'full_library')
          and (
            p_process_filter_contains is null
            or coalesce(snapshot.process_filter, '{}'::jsonb) @> p_process_filter_contains
          )
        )
      )
    order by
      calculation_current desc,
      case when p_snapshot_id is not null then 0 when active.snapshot_id is not null then 0 else 1 end,
      snapshot.created_at desc,
      snapshot.id
    limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'snapshotId', id,
    'scope', scope,
    'processFilter', process_filter,
    'sourceHash', source_hash,
    'createdAt', created_at,
    'isActive', is_active,
    'calculationCurrent', calculation_current,
    'artifact', jsonb_build_object(
      'artifactId', artifact_id,
      'artifactUrl', artifact_url,
      'artifactSha256', artifact_sha256,
      'artifactByteSize', artifact_byte_size,
      'artifactFormat', artifact_format,
      'processCount', process_count,
      'flowCount', flow_count,
      'impactCount', impact_count,
      'snapshotIndexSha256', snapshot_index_sha256,
      'snapshotBuildContractHash', snapshot_build_contract_hash,
      'effectiveScopeHash', effective_scope_hash,
      'dataSnapshotToken', data_snapshot_token,
      'closureBundleHash', closure_bundle_hash
    )
  ))), '[]'::jsonb)
  into v_rows
  from candidates;

  return jsonb_build_object('ok', true, 'data', v_rows);
end
$$;

ALTER FUNCTION "api"."svc_lca_snapshot_candidates"("p_scope" "text", "p_snapshot_id" "uuid", "p_process_filter_contains" "jsonb", "p_limit" integer) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."svc_lca_snapshot_candidates"("p_scope" "text", "p_snapshot_id" "uuid", "p_process_filter_contains" "jsonb", "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."svc_lca_snapshot_candidates"("p_scope" "text", "p_snapshot_id" "uuid", "p_process_filter_contains" "jsonb", "p_limit" integer) TO "service_role";


CREATE OR REPLACE FUNCTION "api"."svc_lca_snapshot_build_enqueue"("p_scope" "text", "p_process_filter" "jsonb", "p_requested_by" "uuid", "p_request_key" "text", "p_job_id" "uuid", "p_snapshot_id" "uuid", "p_payload" "jsonb", "p_payload_schema_version" "text" DEFAULT 'lca.build_snapshot.request.v2'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_calculation_fingerprint text;
  v_scope text := lower(btrim(coalesce(p_scope, '')));
  v_request_key text := nullif(btrim(p_request_key), '');
  v_concurrency_key text;
  v_existing private.worker_jobs%rowtype;
  v_worker jsonb;
  v_worker_id uuid;
  v_resolved_job_id uuid;
  v_resolved_snapshot_id uuid;
begin
  if v_scope not in ('full_library', 'data_product')
     or p_requested_by is null or v_request_key is null
     or p_job_id is null or p_snapshot_id is null then
    return jsonb_build_object('ok', false, 'code', 'INVALID_SNAPSHOT_BUILD_REQUEST', 'status', 400);
  end if;
  if p_process_filter is not null and jsonb_typeof(p_process_filter) <> 'object' then
    return jsonb_build_object('ok', false, 'code', 'INVALID_PROCESS_FILTER', 'status', 400);
  end if;

  select fingerprint into v_calculation_fingerprint
    from private.lca_active_calculation_contract where singleton for share;
  if v_calculation_fingerprint is not null then
    v_request_key := encode(extensions.digest(v_request_key || '|calculation:' || v_calculation_fingerprint, 'sha256'), 'hex');
  end if;
  v_concurrency_key := 'lca.build_snapshot:' || v_scope || ':' || v_request_key;
  perform pg_advisory_xact_lock(hashtextextended(v_concurrency_key, 0));

  select * into v_existing
  from private.worker_jobs
  where concurrency_key = v_concurrency_key
    and status in ('queued', 'running', 'waiting', 'stale', 'blocked')
  order by created_at desc, id
  limit 1;
  if found then
    if v_existing.status = 'blocked' then
      return jsonb_build_object('ok', false, 'code', 'SNAPSHOT_BUILD_BLOCKED', 'status', 409, 'worker_job_id', v_existing.id, 'next_action', 'resolve_worker_job_blocker');
    end if;
    v_resolved_job_id := nullif(v_existing.payload_json ->> 'job_id', '')::uuid;
    v_resolved_snapshot_id := nullif(v_existing.payload_json ->> 'snapshot_id', '')::uuid;
    if v_resolved_job_id is null or v_resolved_snapshot_id is null then
      return jsonb_build_object('ok', false, 'code', 'SNAPSHOT_BUILD_IDENTITY_MISSING', 'status', 409);
    end if;
    return jsonb_build_object(
      'ok', true,
      'mode', case when v_existing.status = 'blocked' then 'blocked' else 'in_progress' end,
      'job_id', v_resolved_job_id,
      'worker_job_id', v_existing.id,
      'snapshot_id', v_resolved_snapshot_id
    );
  end if;

  -- Polling is not a retry intent. Keep the canonical failure until an operator
  -- explicitly retries that job or a changed build contract has a new request key.
  select * into v_existing from private.worker_jobs
  where job_kind = 'lca.build_snapshot'
    and concurrency_key = v_concurrency_key
    and requested_by = p_requested_by
  order by created_at desc, id
  limit 1;
  if found and v_existing.status in ('failed', 'cancelled') then
    return jsonb_build_object(
      'ok', false, 'code', 'SNAPSHOT_BUILD_FAILED', 'status', 409,
      'worker_job_id', v_existing.id,
      'job_id', v_existing.payload_json ->> 'job_id',
      'snapshot_id', v_existing.payload_json ->> 'snapshot_id',
      'next_action', 'explicit_worker_job_retry'
    );
  end if;

  v_worker := private.worker_enqueue_job(
    p_job_kind => 'lca.build_snapshot',
    p_payload_json => coalesce(p_payload, '{}'::jsonb) || jsonb_build_object(
      'job_id', p_job_id, 'snapshot_id', p_snapshot_id, 'scope', v_scope,
      'calculation_fingerprint', v_calculation_fingerprint,
      'process_filter', coalesce(p_process_filter, '{}'::jsonb)
    ),
    p_payload_schema_version => p_payload_schema_version,
    p_subject_type => 'lca_job',
    p_subject_id => p_job_id,
    p_subject_version => p_snapshot_id::text,
    p_requested_by => p_requested_by,
    p_requester_type => 'user',
    p_idempotency_key => p_requested_by::text || ':lca.build_snapshot:' || v_request_key,
    p_request_hash => v_request_key,
    p_concurrency_key => v_concurrency_key,
    p_queue_key => v_scope,
    p_visibility => 'user'
  );
  if coalesce((v_worker ->> 'ok')::boolean, false) is false then return v_worker; end if;
  v_worker_id := (v_worker #>> '{data,id}')::uuid;
  v_resolved_job_id := coalesce(
    nullif(v_worker #>> '{data,payload,job_id}', '')::uuid,
    nullif(v_worker #>> '{data,subjectId}', '')::uuid,
    p_job_id
  );
  v_resolved_snapshot_id := coalesce(
    nullif(v_worker #>> '{data,payload,snapshot_id}', '')::uuid,
    nullif(v_worker #>> '{data,subjectVersion}', '')::uuid,
    p_snapshot_id
  );

  insert into private.lca_network_snapshots (
    id, scope, process_filter, status, created_by, created_at, updated_at
  ) values (
    v_resolved_snapshot_id, v_scope, p_process_filter, 'draft', p_requested_by, now(), now()
  ) on conflict (id) do nothing;

  return jsonb_build_object(
    'ok', true,
    'mode', case
      when v_worker #>> '{data,status}' = 'blocked' then 'blocked'
      when coalesce((v_worker ->> 'reused')::boolean, false) then 'in_progress'
      else 'queued'
    end,
    'job_id', v_resolved_job_id,
    'snapshot_id', v_resolved_snapshot_id,
    'worker_job_id', v_worker_id
  );
end
$$;

ALTER FUNCTION "api"."svc_lca_snapshot_build_enqueue"("p_scope" "text", "p_process_filter" "jsonb", "p_requested_by" "uuid", "p_request_key" "text", "p_job_id" "uuid", "p_snapshot_id" "uuid", "p_payload" "jsonb", "p_payload_schema_version" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "api"."svc_lca_snapshot_build_enqueue"("p_scope" "text", "p_process_filter" "jsonb", "p_requested_by" "uuid", "p_request_key" "text", "p_job_id" "uuid", "p_snapshot_id" "uuid", "p_payload" "jsonb", "p_payload_schema_version" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "api"."svc_lca_snapshot_build_enqueue"("p_scope" "text", "p_process_filter" "jsonb", "p_requested_by" "uuid", "p_request_key" "text", "p_job_id" "uuid", "p_snapshot_id" "uuid", "p_payload" "jsonb", "p_payload_schema_version" "text") TO "service_role";
