CREATE OR REPLACE FUNCTION "private"."lcia_registered_result_availability_v1"("p_result_id" "uuid", "p_snapshot_id" "uuid", "p_require_complete" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
$$;

ALTER FUNCTION "private"."lcia_registered_result_availability_v1"("p_result_id" "uuid", "p_snapshot_id" "uuid", "p_require_complete" boolean) OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."lcia_registered_result_availability_v1"("p_result_id" "uuid", "p_snapshot_id" "uuid", "p_require_complete" boolean) FROM PUBLIC;
