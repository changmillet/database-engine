-- Worker #339 / PR #340: private partial results, complete-only public claims.
-- The immutable Worker snapshot receipt is authoritative; a caller's manifest
-- alone cannot authorize a category, a Portal projection, or a full release.
-- Historical rows and protected source assets are not rewritten.
set lock_timeout = '5s';
set statement_timeout = '120s';

create function private.lcia_category_availability_valid_v1(
  p_receipt jsonb, p_require_complete boolean default false
) returns boolean
language plpgsql immutable set search_path = ''
as $function$
declare
  v_category jsonb;
  v_reason jsonb;
  v_text text;
  v_previous text;
  v_index integer := 0;
  v_available integer := 0;
  v_identity text;
  v_identities text[] := '{}'::text[];
  v_completeness text;
begin
  if jsonb_typeof(p_receipt) is distinct from 'object' then return false; end if;
  if not p_receipt ?& array['schema_version','policy_version','completeness','categories']
     or (select count(*) from jsonb_object_keys(p_receipt)) <> 4
     or p_receipt->>'schema_version' is distinct from 'lcia.category-availability.v1'
     or p_receipt->>'policy_version' is distinct from 'lcia.applicability.source-bound.v3'
     or jsonb_typeof(p_receipt->'categories') is distinct from 'array' then
    return false;
  end if;
  if jsonb_array_length(p_receipt->'categories') not between 1 and 256 then return false; end if;
  for v_category in select value from jsonb_array_elements(p_receipt->'categories') loop
    if jsonb_typeof(v_category) is distinct from 'object' then return false; end if;
    if not v_category ?& array['impact_index','method_id','method_version','status','reasons']
       or (select count(*) from jsonb_object_keys(v_category)) <> 5
       or jsonb_typeof(v_category->'impact_index') is distinct from 'number'
       or v_category->>'impact_index' is distinct from v_index::text
       or jsonb_typeof(v_category->'method_id') is distinct from 'string'
       or v_category->>'method_id' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or jsonb_typeof(v_category->'method_version') is distinct from 'string'
       or v_category->>'method_version' !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{3}$'
       or coalesce(v_category->>'status','') not in ('available','unavailable')
       or jsonb_typeof(v_category->'reasons') is distinct from 'array' then
      return false;
    end if;
    v_identity := (v_category->>'method_id') || ':' || (v_category->>'method_version');
    if v_identity = any(v_identities) then return false; end if;
    v_identities := array_append(v_identities, v_identity);
    if jsonb_array_length(v_category->'reasons') > 32
       or ((v_category->>'status' = 'available') <> (jsonb_array_length(v_category->'reasons') = 0)) then
      return false;
    end if;
    v_previous := null;
    for v_reason in select value from jsonb_array_elements(v_category->'reasons') loop
      if jsonb_typeof(v_reason) is distinct from 'string' then return false; end if;
      v_text := v_reason #>> '{}';
      if v_text !~ '^[a-z0-9_]{1,160}$'
         or (v_previous is not null and v_previous collate "C" >= v_text collate "C") then
        return false;
      end if;
      v_previous := v_text;
    end loop;
    if v_category->>'status' = 'available' then v_available := v_available + 1; end if;
    v_index := v_index + 1;
  end loop;
  v_completeness := case when v_available = v_index then 'complete'
    when v_available = 0 then 'unavailable' else 'partial' end;
  return p_receipt->>'completeness' is not distinct from v_completeness
    and (not coalesce(p_require_complete, false) or v_completeness = 'complete');
end
$function$;
alter function private.lcia_category_availability_valid_v1(jsonb,boolean) owner to postgres;
revoke all on function private.lcia_category_availability_valid_v1(jsonb,boolean)
  from public, anon, authenticated, service_role, api_internal_executor;

create function private.lcia_registered_result_availability_v1(
  p_result_id uuid, p_snapshot_id uuid, p_require_complete boolean default false
) returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
  v_result private.lca_results%rowtype;
  v_snapshot private.lca_network_snapshots%rowtype;
  v_receipt jsonb;
begin
  select * into v_result from private.lca_results where id = p_result_id;
  if v_result.id is null or v_result.snapshot_id is distinct from p_snapshot_id then return null; end if;
  select * into v_snapshot from private.lca_network_snapshots where id = p_snapshot_id;
  v_receipt := v_snapshot.process_filter->'lcia_availability';
  if v_snapshot.id is null or v_snapshot.status <> 'ready'
     or v_snapshot.process_filter->>'lcia_applicability_policy_version'
          is distinct from 'lcia.applicability.source-bound.v3'
     or not private.lcia_category_availability_valid_v1(v_receipt, p_require_complete)
     or v_result.diagnostics->'lcia_availability' is distinct from v_receipt then
    return null;
  end if;
  return v_receipt;
end
$function$;
alter function private.lcia_registered_result_availability_v1(uuid,uuid,boolean) owner to postgres;
revoke all on function private.lcia_registered_result_availability_v1(uuid,uuid,boolean)
  from public, anon, authenticated, service_role, api_internal_executor;

create function private.lcia_package_availability_valid_v1(
  p_package_id uuid, p_require_complete boolean default false
) returns boolean
language plpgsql stable security definer set search_path = ''
as $function$
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
$function$;
alter function private.lcia_package_availability_valid_v1(uuid,boolean) owner to postgres;
revoke all on function private.lcia_package_availability_valid_v1(uuid,boolean)
  from public, anon, authenticated, service_role, api_internal_executor;

create function private.lcia_package_category_availability_guard_v1()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_result private.lca_results%rowtype;
  v_snapshot private.lca_network_snapshots%rowtype;
  v_receipt jsonb;
  v_available jsonb;
  v_schema text;
begin
  select * into v_result from private.lca_results where id = new.result_id;
  select * into v_snapshot from private.lca_network_snapshots where id = new.snapshot_id;
  -- Legacy private metadata remains import/read-compatible. Its missing receipt
  -- never passes the independent current-compute or public-publication gates.
  if v_snapshot.process_filter->>'lcia_applicability_policy_version'
       is distinct from 'lcia.applicability.source-bound.v3'
     and not new.artifact_manifest ? 'lciaAvailability'
     and not coalesce(v_result.diagnostics, '{}'::jsonb) ? 'lcia_availability' then
    return new;
  end if;
  v_receipt := private.lcia_registered_result_availability_v1(new.result_id, new.snapshot_id, false);
  v_schema := case when v_receipt->>'completeness' = 'complete' then 'tiangong.calculation-bundle.v2' else 'tiangong.calculation-bundle.v3' end;
  if v_receipt is null
     or new.artifact_manifest->'lciaAvailability' is distinct from v_receipt
     or v_result.job_id is distinct from new.build_id
     or v_result.worker_job_id is distinct from new.build_worker_job_id
     or coalesce(v_result.artifact_sha256,'') !~ '^[0-9a-f]{64}$'
     or new.package_result_hash is distinct from v_result.artifact_sha256
     or new.result_artifact_ref->>'artifactSha256' is distinct from v_result.artifact_sha256
     or new.artifact_manifest->'calculationBundle' is distinct from v_result.diagnostics->'calculation_bundle'
     or v_result.diagnostics->'calculation_bundle'->>'schemaVersion' is distinct from v_schema then
    raise exception 'lcia_package_availability_binding_invalid' using errcode = '23514';
  end if;
  select coalesce(jsonb_agg(category->'method_id' order by ordinality), '[]'::jsonb)
    into v_available
    from jsonb_array_elements(v_receipt->'categories') with ordinality as item(category, ordinality)
    where category->>'status' = 'available';
  if new.available_impact_categories is distinct from v_available
     or (new.default_impact_category is not null and not v_available ? new.default_impact_category)
     or (v_receipt->>'completeness' <> 'complete'
       and (new.artifact_manifest ? 'portalProjectionId'
         or new.artifact_manifest ? 'portalProjectionContentHash')) then
    raise exception 'lcia_package_category_claim_invalid' using errcode = '23514';
  end if;
  return new;
end
$function$;
alter function private.lcia_package_category_availability_guard_v1() owner to postgres;
revoke all on function private.lcia_package_category_availability_guard_v1()
  from public, anon, authenticated, service_role, api_internal_executor;
create trigger lcia_result_packages_category_availability_v1
  before insert on private.lcia_result_packages
  for each row execute function private.lcia_package_category_availability_guard_v1();

create function private.lcia_public_category_completeness_guard_v1()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_package_id uuid;
  v_registered boolean := false;
  v_calculation_id uuid;
begin
  if tg_table_name = 'portal_lcia_projection_headers' then
    if new.status = 'failed' then return new; end if;
    if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
    select exists (
      select 1 from private.lca_results as result
      where result.worker_job_id = new.build_worker_job_id
        and result.artifact_sha256 = new.result_artifact_sha256
        and private.lcia_registered_result_availability_v1(result.id, result.snapshot_id, true) is not null
    ) into v_registered;
  elsif tg_table_name = 'lca_release_runs' then
    if new.status not in ('ready_for_approval','approved','published') then return new; end if;
    if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
    if coalesce(new.calculation_bundle_ref->>'calculationId','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'lcia_complete_result_required' using errcode = '23514';
    end if;
    v_calculation_id := (new.calculation_bundle_ref->>'calculationId')::uuid;
    select exists (
      select 1 from private.lca_results as result
      where result.job_id = v_calculation_id
        and result.diagnostics->'calculation_bundle'->>'bundleContentHash' = new.calculation_bundle_hash
        and result.diagnostics->'calculation_bundle'->>'schemaVersion' = 'tiangong.calculation-bundle.v2'
        and new.calculation_bundle_ref @> ((result.diagnostics->'calculation_bundle') - 'downloads')
        and private.lcia_registered_result_availability_v1(result.id, result.snapshot_id, true) is not null
    ) into v_registered;
  else
    if tg_table_name = 'lcia_result_publications' then
      if tg_op = 'UPDATE' and (not new.is_current or (old.is_current and new.status = old.status and new.package_id = old.package_id)) then return new; end if;
      v_package_id := new.package_id;
    elsif tg_table_name = 'portal_lcia_projection_publications' then
      if tg_op = 'UPDATE' and new.status = 'revoked' then return new; end if;
      v_package_id := new.package_id;
    end if;
    v_registered := private.lcia_package_availability_valid_v1(v_package_id, true);
  end if;
  if not coalesce(v_registered, false) then
    raise exception 'lcia_complete_result_required' using errcode = '23514';
  end if;
  return new;
end
$function$;
alter function private.lcia_public_category_completeness_guard_v1() owner to postgres;
revoke all on function private.lcia_public_category_completeness_guard_v1()
  from public, anon, authenticated, service_role, api_internal_executor;
create trigger portal_lcia_projection_category_completeness_v1
  before insert or update on private.portal_lcia_projection_headers
  for each row execute function private.lcia_public_category_completeness_guard_v1();
create trigger lcia_result_publications_category_completeness_v1
  before insert or update on private.lcia_result_publications
  for each row execute function private.lcia_public_category_completeness_guard_v1();
create trigger portal_lcia_publications_category_completeness_v1
  before insert or update on private.portal_lcia_projection_publications
  for each row execute function private.lcia_public_category_completeness_guard_v1();
create trigger lca_release_category_completeness_v1
  before insert or update on private.lca_release_runs
  for each row execute function private.lcia_public_category_completeness_guard_v1();

-- Reuse the established lease/certificate-guarded V2 insertion path for the
-- narrowly defined V3 private-partial fallback. The original remains intact.
alter function private.cmd_lcia_result_package_mark_ready(
  uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb
) rename to lcia_package_mark_ready_before_category_availability_v1;
revoke all on function private.lcia_package_mark_ready_before_category_availability_v1(
  uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb
) from public, anon, authenticated, service_role, api_internal_executor;

create function private.cmd_lcia_result_package_mark_ready(
  p_build_worker_job_id uuid, p_package_version text, p_snapshot_id uuid, p_result_id uuid,
  p_latest_all_unit_result_id uuid default null,
  p_result_artifact_ref jsonb default '{}'::jsonb,
  p_query_artifact_ref jsonb default '{}'::jsonb,
  p_artifact_manifest jsonb default '{}'::jsonb,
  p_available_impact_categories jsonb default '[]'::jsonb,
  p_default_impact_category text default null,
  p_package_result_hash text default null,
  p_audit jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = ''
as $function$
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
$function$;
alter function private.cmd_lcia_result_package_mark_ready(
  uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb
) owner to postgres;
revoke all on function private.cmd_lcia_result_package_mark_ready(
  uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb
) from public, anon, authenticated;
grant execute on function private.cmd_lcia_result_package_mark_ready(
  uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb
) to service_role, api_internal_executor;

-- This digest binds the original private request body, not an approval decision.
-- A lease is deliberately excluded so a new current claimant can recover the
-- same immutable package without accepting a changed request body.
create function private.lcia_partial_package_request_hash_v1(p_job private.worker_jobs)
returns text language plpgsql immutable set search_path = ''
as $function$
begin
  return encode(extensions.digest(convert_to(jsonb_build_array(
    'lcia.private-partial-ready.request.v1',p_job.id,p_job.job_kind,p_job.worker_runtime,
    p_job.worker_queue,p_job.subject_type,p_job.subject_id,p_job.subject_version,
    p_job.requested_by,p_job.team_id,p_job.payload_schema_version,p_job.payload_json
  )::text,'UTF8'),'sha256'),'hex');
end
$function$;
alter function private.lcia_partial_package_request_hash_v1(private.worker_jobs) owner to postgres;
revoke all on function private.lcia_partial_package_request_hash_v1(private.worker_jobs)
  from public, anon, authenticated, service_role, api_internal_executor;

create function private.lcia_partial_package_binding_valid_v1(
  p_package_id uuid,p_build_worker_job_id uuid
) returns boolean language plpgsql stable security definer set search_path = ''
as $function$
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
$function$;
alter function private.lcia_partial_package_binding_valid_v1(uuid,uuid) owner to postgres;
revoke all on function private.lcia_partial_package_binding_valid_v1(uuid,uuid)
  from public, anon, authenticated, service_role, api_internal_executor;

create function private.svc_lcia_result_package_ready_readback_v1(
  p_build_worker_job_id uuid,p_current_lease_token uuid
) returns jsonb language plpgsql security definer set search_path = ''
as $function$
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
$function$;
alter function private.svc_lcia_result_package_ready_readback_v1(uuid,uuid) owner to postgres;
revoke all on function private.svc_lcia_result_package_ready_readback_v1(uuid,uuid)
  from public, anon, authenticated, api_internal_executor;
grant execute on function private.svc_lcia_result_package_ready_readback_v1(uuid,uuid) to service_role;

create function private.svc_lcia_result_package_partial_mark_ready_v1(
  p_build_worker_job_id uuid,p_lease_token uuid,p_package_version text,p_snapshot_id uuid,p_result_id uuid,
  p_latest_all_unit_result_id uuid default null,p_result_artifact_ref jsonb default '{}'::jsonb,
  p_query_artifact_ref jsonb default '{}'::jsonb,p_artifact_manifest jsonb default '{}'::jsonb,
  p_available_impact_categories jsonb default '[]'::jsonb,p_default_impact_category text default null,
  p_package_result_hash text default null,p_audit jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = ''
as $function$
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
$function$;
alter function private.svc_lcia_result_package_partial_mark_ready_v1(uuid,uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb) owner to postgres;
revoke all on function private.svc_lcia_result_package_partial_mark_ready_v1(uuid,uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb)
  from public, anon, authenticated, api_internal_executor;
grant execute on function private.svc_lcia_result_package_partial_mark_ready_v1(uuid,uuid,text,uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb) to service_role;

-- New scope requests cannot reuse a completed pre-applicability numerical scan.
-- The matching Worker explicitly supports r7; old requests keep frozen revisions.
insert into private.lcia_scope_closure_config(singleton,expected_validator_scanner_fingerprint)
values(true,'scope-closure-validator-scanner.v1+cutoff-readiness-r7')
on conflict(singleton) do update
set expected_validator_scanner_fingerprint = excluded.expected_validator_scanner_fingerprint,
    updated_at = statement_timestamp();

-- Optional private exports preserve partial evidence and never grant publication.
create or replace function api.svc_lca_calculation_export(
  p_requested_by uuid, p_package_id uuid, p_format text default 'parquet',
  p_enqueue boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_package private.lcia_result_packages%rowtype;
  v_bundle jsonb;
  v_job private.worker_jobs%rowtype;
  v_hash text;
  v_key text;
  v_enqueued jsonb;
begin
  if not coalesce(util.is_service_request(), false) then
    return api.lcia_result_error('SERVICE_ROLE_REQUIRED', 403, 'SERVICE ROLE REQUIRED');
  end if;
  if p_requested_by is null or not exists (
    select 1 from private.roles where user_id = p_requested_by
      and team_id = '00000000-0000-0000-0000-000000000000'::uuid
      and role = 'data_product_manager'
  ) then
    return api.lcia_result_error('not_data_product_manager', 403, 'not data product manager');
  end if;
  if p_format is null or p_format not in ('parquet', 'csv', 'lcia_xlsx', 'lcia_csv', 'audit') then
    return api.lcia_result_error('invalid_export_format', 400, 'invalid export format');
  end if;
  select * into v_package from private.lcia_result_packages where id = p_package_id;
  if v_package.id is null then
    return api.lcia_result_error('package_not_found', 404, 'package not found');
  end if;
  if v_package.status <> 'preview_ready' or v_package.result_id is null then
    return api.lcia_result_error('calculation_not_ready', 409, 'calculation not ready');
  end if;
  select coalesce(v_package.artifact_manifest->'calculationBundle', diagnostics->'calculation_bundle')
    into v_bundle from private.lca_results where id = v_package.result_id;
  if v_bundle is null or coalesce(v_bundle->>'bundleContentHash', '') !~ '^[0-9a-f]{64}$'
    or coalesce(v_bundle->>'manifestSha256', '') !~ '^[0-9a-f]{64}$'
    or coalesce(v_bundle->>'schemaVersion', '') not in ('tiangong.calculation-bundle.v2','tiangong.calculation-bundle.v3') then
    return api.lcia_result_error('calculation_bundle_not_available', 409, 'calculation bundle not available');
  end if;
  if (v_bundle->>'schemaVersion' = 'tiangong.calculation-bundle.v3'
      or v_package.artifact_manifest ? 'lciaAvailability')
     and not private.lcia_package_availability_valid_v1(v_package.id,false) then
    return api.lcia_result_error('lcia_package_availability_binding_invalid',409,'Private export requires exact category availability');
  end if;
  v_hash := encode(extensions.digest(convert_to(jsonb_build_array(
    'lca.calculation_export.request.v1', p_package_id, v_bundle->>'bundleContentHash',
    v_bundle->>'manifestSha256', p_format
  )::text, 'UTF8'), 'sha256'), 'hex');
  v_key := 'lca.calculation_export:' || v_hash;
  perform pg_advisory_xact_lock(hashtextextended(v_key, 0));
  select * into v_job from private.worker_jobs
    where job_kind = 'lca.calculation_export' and concurrency_key = v_key
    order by created_at desc, id limit 1;
  if v_job.id is null and coalesce(p_enqueue, false) then
    v_enqueued := private.worker_enqueue_job(
      p_job_kind => 'lca.calculation_export',
      p_payload_json => jsonb_build_object('packageId', p_package_id, 'bundle', v_bundle - 'downloads', 'format', p_format),
      p_payload_schema_version => 'lca.calculation_export.request.v1',
      p_subject_type => 'lcia_result_package', p_subject_id => p_package_id,
      p_subject_version => v_bundle->>'bundleContentHash', p_requested_by => p_requested_by,
      p_requester_type => 'user', p_idempotency_key => v_key, p_request_hash => v_hash,
      p_concurrency_key => v_key, p_queue_key => p_package_id::text, p_visibility => 'user'
    );
    if coalesce((v_enqueued->>'ok')::boolean, false) is false then return v_enqueued; end if;
    select * into v_job from private.worker_jobs where id = (v_enqueued#>>'{data,id}')::uuid;
  end if;
  -- Read/status never enqueue. Repeated explicit requests reuse terminal outcomes too.
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'packageId', p_package_id, 'format', p_format,
    'bundleContentHash', v_bundle->>'bundleContentHash',
    'sourceManifestSha256', v_bundle->>'manifestSha256',
    'workerJobId', v_job.id, 'status', coalesce(v_job.status, 'not_requested'),
    'progress', v_job.progress, 'errorCode', v_job.error_code,
    'errorMessage', v_job.error_message, 'retryable', v_job.retryable,
    'nextAction', case when v_job.status in ('failed', 'cancelled', 'blocked') then 'explicit_worker_job_retry' else null end,
    'result', case when v_job.status = 'completed' then v_job.result_json else null end
  ));
end;
$$;
alter function api.svc_lca_calculation_export(uuid,uuid,text,boolean) owner to postgres;
revoke all on function api.svc_lca_calculation_export(uuid,uuid,text,boolean) from public, anon, authenticated;
grant execute on function api.svc_lca_calculation_export(uuid,uuid,text,boolean) to service_role;
-- The existing export capability identity and grants remain unchanged.

notify pgrst, 'reload schema';
