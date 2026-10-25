CREATE OR REPLACE FUNCTION "private"."lcia_package_category_availability_guard_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
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
$_$;

ALTER FUNCTION "private"."lcia_package_category_availability_guard_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."lcia_package_category_availability_guard_v1"() FROM PUBLIC;
