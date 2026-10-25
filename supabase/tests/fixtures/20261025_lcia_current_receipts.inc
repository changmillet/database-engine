-- Test setup only, included inside each caller's rollback transaction.
-- These synthetic receipts bind the explicitly supplied frozen axis for SQL
-- authority tests. They perform no characterization or scientific qualification.
create or replace function pg_temp.worker339_bind_current_result(
  p_result_id uuid, p_frozen_methods jsonb, p_bundle_ref jsonb default null
) returns void language plpgsql set search_path = '' as $fixture$
declare
  v_result private.lca_results%rowtype;
  v_job private.worker_jobs%rowtype;
  v_receipt jsonb;
  v_ref jsonb;
  v_job_id uuid;
begin
  select * into strict v_result from private.lca_results where id=p_result_id;
  select * into v_job from private.worker_jobs where id=v_result.worker_job_id;
  v_job_id:=case when v_job.job_kind='lcia_result.package_build' then v_job.subject_id else v_result.job_id end;
  if jsonb_typeof(p_frozen_methods) is distinct from 'array' or jsonb_array_length(p_frozen_methods)=0 then
    raise exception 'fixture requires the explicit frozen method axis';
  end if;
  select jsonb_build_object('schema_version','lcia.category-availability.v1',
    'policy_version','lcia.applicability.source-bound.v3','completeness','complete',
    'categories',jsonb_agg(jsonb_build_object('impact_index',(ordinality-1)::integer,
      'method_id',method->>'id','method_version',method->>'version','status','available','reasons','[]'::jsonb) order by ordinality))
    into v_receipt from jsonb_array_elements(p_frozen_methods) with ordinality as axis(method,ordinality);
  if not private.lcia_category_availability_valid_v1(v_receipt,true) then raise exception 'fixture method axis is not canonical'; end if;
  v_ref:=coalesce(p_bundle_ref,jsonb_build_object('schemaVersion','tiangong.calculation-bundle.v2',
    'calculationId',v_job_id,'bundleContentHash',v_result.artifact_sha256,'manifestSha256',repeat('e',64),
    'manifestUrl','s3://worker339-fixture/'||p_result_id::text||'/manifest.json','manifestByteSize',100,'artifactCount',3));
  if v_ref->>'calculationId' is distinct from v_job_id::text or v_ref->>'schemaVersion' is distinct from 'tiangong.calculation-bundle.v2' then
    raise exception 'fixture bundle identity differs from its producing result';
  end if;
  update private.lca_network_snapshots set process_filter=coalesce(process_filter,'{}'::jsonb)||
    jsonb_build_object('lcia_applicability_policy_version','lcia.applicability.source-bound.v3',
      'lcia_availability',v_receipt,'lcia_enabled',true,'fixture_frozen_method_axis',p_frozen_methods)
    where id=v_result.snapshot_id;
  update private.lca_results set job_id=v_job_id,
    diagnostics=coalesce(diagnostics,'{}'::jsonb)||jsonb_build_object('lcia_availability',v_receipt,'calculation_bundle',v_ref)
    where id=p_result_id;
  update private.lca_latest_all_unit_results set job_id=v_job_id where result_id=p_result_id;
end
$fixture$;
revoke all on function pg_temp.worker339_bind_current_result(uuid,jsonb,jsonb) from public,anon,authenticated,service_role;

create or replace function pg_temp.worker339_result_manifest(p_result_id uuid,p_extra jsonb default '{}')
returns jsonb language sql stable set search_path = '' as $fixture$
  select p_extra||jsonb_build_object('lciaAvailability',diagnostics->'lcia_availability',
    'calculationBundle',diagnostics->'calculation_bundle') from private.lca_results where id=p_result_id
$fixture$;
revoke all on function pg_temp.worker339_result_manifest(uuid,jsonb) from public,anon,authenticated;
grant execute on function pg_temp.worker339_result_manifest(uuid,jsonb) to service_role;
