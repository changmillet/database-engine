CREATE OR REPLACE FUNCTION "private"."lcia_public_category_completeness_guard_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
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
$_$;

ALTER FUNCTION "private"."lcia_public_category_completeness_guard_v1"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."lcia_public_category_completeness_guard_v1"() FROM PUBLIC;
