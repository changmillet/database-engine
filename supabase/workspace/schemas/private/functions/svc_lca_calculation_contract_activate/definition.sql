CREATE OR REPLACE FUNCTION "private"."svc_lca_calculation_contract_activate"("p_descriptor" "text", "p_expected_fingerprint" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "private"."svc_lca_calculation_contract_activate"("p_descriptor" "text", "p_expected_fingerprint" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "private"."svc_lca_calculation_contract_activate"("p_descriptor" "text", "p_expected_fingerprint" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "private"."svc_lca_calculation_contract_activate"("p_descriptor" "text", "p_expected_fingerprint" "text") TO "service_role";
