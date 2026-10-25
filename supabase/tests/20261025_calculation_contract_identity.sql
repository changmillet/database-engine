begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

create temporary table candidate_webhook_calls (
  edge_function text not null,
  body jsonb not null,
  timeout_milliseconds integer not null
) on commit drop;

create or replace function util.invoke_edge_function(
  name text,
  body jsonb,
  timeout_milliseconds integer default ((5 * 60) * 1000)
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into pg_temp.candidate_webhook_calls(
    edge_function,
    body,
    timeout_milliseconds
  ) values (name, body, timeout_milliseconds);
end;
$$;

select is(
  private.lcia_scope_closure_worker_canonical_sha256(
    '{"z":1,"a":[3,{"b":true}]}'::jsonb
  ),
  '95f7be01f2a50d2296efb7eeba30ac587ef545c9501c9d47740490f143f6b593',
  'candidate document hashing matches the Worker canonical JSON golden vector'
);
select is(
  (
    select count(*)
    from private.lcia_scope_closure_reviewed_lcia_methods
  ),
  25::bigint,
  'candidate LCIA allowlist matches the deployed Worker reviewed method count'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous
) values (
  '00000000-0000-0000-0000-000000000000',
  'c7240000-0000-4000-8000-000000000001',
  'authenticated',
  'authenticated',
  'initial-candidate-closure@example.com',
  'x',
  now(),
  '{}',
  '{}',
  now(),
  now(),
  false,
  false
);
insert into private.users(id, raw_user_meta_data, contact)
values ('c7240000-0000-4000-8000-000000000001', '{}', null);
insert into private.teams(id, json, rank, is_public)
values (
  '00000000-0000-0000-0000-000000000000',
  '{"name":"System"}',
  0,
  false
)
on conflict (id) do nothing;
insert into private.roles(user_id, team_id, role)
values (
  'c7240000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'data_product_manager'
);

insert into public.processes(
  id, version, state_code, json, json_ordered, user_id
) values
(
  'c7240000-0000-4000-8000-000000000010',
  '01.00.000',
  100,
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"c7240000-0000-4000-8000-000000000010"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"c7240000-0000-4000-8000-000000000010"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  'c7240000-0000-4000-8000-000000000001'
),
(
  'c7240000-0000-4000-8000-000000000010',
  '02.00.000',
  100,
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"c7240000-0000-4000-8000-000000000010"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"02.00.000"}},"versionMarker":"latest"}}',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"c7240000-0000-4000-8000-000000000010"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"02.00.000"}},"versionMarker":"latest"}}',
  'c7240000-0000-4000-8000-000000000001'
),
(
  'c7240000-0000-4000-8000-000000000011',
  '01.00.000',
  0,
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"c7240000-0000-4000-8000-000000000011"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  '{"processDataSet":{"processInformation":{"dataSetInformation":{"common:UUID":"c7240000-0000-4000-8000-000000000011"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.00.000"}}}}',
  'c7240000-0000-4000-8000-000000000001'
);

insert into public.lciamethods(
  id, version, state_code, json, json_ordered, user_id
) values (
  '9ec743ea-6b00-400d-a53b-61547a3fc03c',
  '01.01.000',
  0,
  '{"LCIAMethodDataSet":{"LCIAMethodInformation":{"dataSetInformation":{"common:UUID":"503699e0-eca9-4089-8bf8-e0f49c93e578"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.01.000"}}}}',
  '{"LCIAMethodDataSet":{"LCIAMethodInformation":{"dataSetInformation":{"common:UUID":"503699e0-eca9-4089-8bf8-e0f49c93e578"}},"administrativeInformation":{"publicationAndOwnership":{"common:dataSetVersion":"01.01.000"}}}}',
  'c7240000-0000-4000-8000-000000000001'
)
on conflict (id, version) do update
set state_code = excluded.state_code,
    json = excluded.json,
    json_ordered = excluded.json_ordered,
    user_id = excluded.user_id;


create temporary table contract_results(label text primary key, value jsonb);
grant all on contract_results to authenticated, service_role;
create function pg_temp.scope() returns jsonb language sql as $$
 select '{"coverageMode":"subset","processes":[{"id":"c7240000-0000-4000-8000-000000000010","version":"01.00.000"}],"lciaMethods":[{"id":"503699e0-eca9-4089-8bf8-e0f49c93e578","version":"01.01.000"}]}'::jsonb;
$$;
grant execute on function pg_temp.scope() to authenticated, service_role;
create function pg_temp.queue_build(p_job uuid, p_snapshot uuid) returns jsonb language sql as $$
 select api.svc_lca_snapshot_build_enqueue('full_library','{"all_states":false,"process_states":[100]}'::jsonb,
 'c7240000-0000-4000-8000-000000000001','same-input-request',p_job,p_snapshot,
 '{"type":"build_snapshot","process_states":"100","calculation_fingerprint":"caller-spoof"}'::jsonb);
$$;
grant execute on function pg_temp.queue_build(uuid,uuid) to service_role;
select ok(private.lca_calculation_contract_is_current(null), 'bootstrap preserves existing admission before explicit activation');
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','c7240000-0000-4000-8000-000000000001',true);
set local role authenticated;
insert into contract_results values ('bootstrap',api.cmd_lcia_scope_closure_check_request_v2(pg_temp.scope(),'contract-bootstrap'));
reset role;
select set_config('request.jwt.claim.role','service_role',true);
select ok(not (private.svc_lcia_scope_closure_check_get_worker_input((select (value#>>'{data,closureCheckId}')::uuid from contract_results where label='bootstrap'))->'data' ? 'calculationFingerprint'),'bootstrap input omits the additive field for legacy workers');
select set_config('request.jwt.claim.role','',true);
select ok(not has_table_privilege('service_role','private.lca_calculation_contracts','UPDATE'), 'descriptor records cannot be rewritten by service clients');
select ok(not has_function_privilege('authenticated','private.svc_lca_calculation_contract_activate(text,text)','EXECUTE'), 'browser cannot activate an implementation');
select ok(not has_function_privilege('anon','private.svc_lca_calculation_contract_activate(text,text)','EXECUTE'), 'anonymous cannot activate an implementation');
select is(private.svc_lca_calculation_contract_activate('{"engine":"a"}',null)->>'code','SERVICE_ROLE_REQUIRED','activation checks service authority even under an owner session');
select set_config('request.jwt.claim.role','service_role',true);
set local role service_role;
select is(private.svc_lca_calculation_contract_activate('null',null)->>'code','INVALID_CALCULATION_DESCRIPTOR','descriptor must be an object');
select is(private.svc_lca_calculation_contract_activate('invalid',null)->>'code','INVALID_CALCULATION_DESCRIPTOR','malformed JSON is rejected');
insert into contract_results values ('activate-a',private.svc_lca_calculation_contract_activate('{"engine":"a"}',null));
select is((select value->>'ok' from contract_results where label='activate-a'),'true','first activation succeeds');
insert into contract_results values ('queue-a',pg_temp.queue_build('87300000-0000-4000-8000-000000000011','87300000-0000-4000-8000-000000000012'));
select is((select value->>'ok' from contract_results where label='queue-a'),'true','ordinary snapshot build queues under the first identity');
select is(private.svc_lca_calculation_contract_activate('{"engine":"b"}',null)->>'code','CALCULATION_ACTIVATION_CONFLICT','stale expected identity cannot overwrite current identity');
reset role;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','c7240000-0000-4000-8000-000000000001',true);
set local role authenticated;
insert into contract_results values ('request-a',api.cmd_lcia_scope_closure_check_request_v2(pg_temp.scope(),'contract-a'));
select is((select value->>'ok' from contract_results where label='request-a'),'true','request under first contract succeeds');
reset role;
update private.lcia_scope_closure_scan_executions set status='completed',completed_check_id=(select (value#>>'{data,closureCheckId}')::uuid from contract_results where label='request-a') where id=(select (value#>>'{data,scanExecutionId}')::uuid from contract_results where label='request-a');
select set_config('request.jwt.claim.role','service_role',true);
set local role service_role;
insert into contract_results values ('activate-b',private.svc_lca_calculation_contract_activate('{"engine":"b"}',(select value->>'fingerprint' from contract_results where label='activate-a')));
select is((select value->>'ok' from contract_results where label='activate-b'),'true','second arbitrary contract activates without scanner or application change');
insert into contract_results values ('queue-b',pg_temp.queue_build('87300000-0000-4000-8000-000000000021','87300000-0000-4000-8000-000000000022'));
insert into contract_results values ('queue-b-retry',pg_temp.queue_build('87300000-0000-4000-8000-000000000031','87300000-0000-4000-8000-000000000032'));
select isnt((select value->>'worker_job_id' from contract_results where label='queue-a'),(select value->>'worker_job_id' from contract_results where label='queue-b'),'new calculation identity separates ordinary build jobs');
select is((select value->>'worker_job_id' from contract_results where label='queue-b'),(select value->>'worker_job_id' from contract_results where label='queue-b-retry'),'same active build identity coalesces');
select ok(not private.lca_calculation_contract_is_current((select value->>'fingerprint' from contract_results where label='activate-a')), 'old identity is no longer current');
select ok(not private.lca_calculation_contract_is_current(null), 'missing historical identity is no longer current');
select ok(private.lca_calculation_contract_is_current((select value->>'fingerprint' from contract_results where label='activate-b')), 'new identity is current');
reset role;
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;
insert into contract_results values ('retry-a',api.cmd_lcia_scope_closure_check_request_v2(pg_temp.scope(),'contract-a'));
insert into contract_results values ('request-b',api.cmd_lcia_scope_closure_check_request_v2(pg_temp.scope(),'contract-b'));
select is((select value#>>'{data,closureCheckId}' from contract_results where label='retry-a'),(select value#>>'{data,closureCheckId}' from contract_results where label='request-a'),'retry retains its original request');
select is((select value#>>'{data,calculationFingerprint}' from contract_results where label='retry-a'),(select value->>'fingerprint' from contract_results where label='activate-a'),'retry retains its original computation identity');
select is((select value#>>'{data,calculationFingerprint}' from contract_results where label='request-b'),(select value->>'fingerprint' from contract_results where label='activate-b'),'new token uses current computation identity');
select isnt((select value#>>'{data,scanExecutionId}' from contract_results where label='request-b'),(select value#>>'{data,scanExecutionId}' from contract_results where label='request-a'),'new algorithm cannot coalesce with old numerical execution');
select is(api.cmd_lcia_scope_closure_check_request_v2(null,'contract-a')->>'code','idempotency_payload_conflict','null payload cannot bypass token conflict checks');
select is(api.cmd_lcia_scope_closure_check_request_v2(pg_temp.scope() || '{"coverageMode":"global_eligible"}','contract-a')->>'code','idempotency_payload_conflict','changed payload cannot reuse a pinned token');
reset role;
select is((select count(distinct validator_scanner_fingerprint) from private.lcia_scope_closure_scan_executions where id in (select (value#>>'{data,scanExecutionId}')::uuid from contract_results where label in ('request-a','request-b'))),1::bigint,'scanner identity stays unchanged across calculation identities');
select is((select count(distinct data_snapshot_token) from private.lcia_scope_closure_scan_executions where id in (select (value#>>'{data,scanExecutionId}')::uuid from contract_results where label in ('request-a','request-b'))),1::bigint,'identical data snapshots are not invalidated or rewritten');
select set_config('request.jwt.claim.role','service_role',true);
select is(private.svc_lcia_scope_closure_check_get_worker_input((select (value#>>'{data,closureCheckId}')::uuid from contract_results where label='request-b'))#>>'{data,calculationFingerprint}',(select value->>'fingerprint' from contract_results where label='activate-b'),'worker receives the pinned identity before execution');
insert into private.lca_network_snapshots(id,scope,process_filter,status) values ('87300000-0000-4000-8000-000000000001','full_library','{}','ready');
insert into private.lca_snapshot_artifacts(snapshot_id,artifact_url,artifact_sha256,artifact_byte_size,artifact_format,process_count,flow_count,impact_count,a_nnz,b_nnz,c_nnz,status)
values ('87300000-0000-4000-8000-000000000001','s3://history/immutable',repeat('a',64),1,'npz',1,1,1,1,1,1,'ready');
select is(api.svc_lca_snapshot_candidates('full_library','87300000-0000-4000-8000-000000000001')#>>'{data,0,calculationCurrent}','false','old candidate remains readable but cannot back current calculation');
select is(api.svc_lca_snapshot_candidates('full_library','87300000-0000-4000-8000-000000000001')#>>'{data,0,artifact,artifactUrl}','s3://history/immutable','historical bytes stay readable');
update private.lca_network_snapshots set process_filter=jsonb_build_object('calculation_fingerprint',(select value->>'fingerprint' from contract_results where label='activate-b')) where id='87300000-0000-4000-8000-000000000001';
select is(api.svc_lca_snapshot_candidates('full_library','87300000-0000-4000-8000-000000000001')#>>'{data,0,calculationCurrent}','true','current opaque identity is compatible without geography');
select is((select payload_json->>'calculation_fingerprint' from private.worker_jobs where id=(select (value->>'worker_job_id')::uuid from contract_results where label='queue-b')),(select value->>'fingerprint' from contract_results where label='activate-b'),'database binds queue payload from active identity rather than caller input');
insert into private.lca_network_snapshots(id,scope,process_filter,status) values ('87300000-0000-4000-8000-000000000002','full_library','{}','ready');
insert into private.lca_snapshot_artifacts(snapshot_id,artifact_url,artifact_sha256,artifact_byte_size,artifact_format,process_count,flow_count,impact_count,a_nnz,b_nnz,c_nnz,status)
values ('87300000-0000-4000-8000-000000000002','s3://history/old-active',repeat('b',64),1,'npz',1,1,1,1,1,1,'ready');
insert into private.lca_active_snapshots(scope,snapshot_id,source_hash) values ('full_library','87300000-0000-4000-8000-000000000002','historical-source') on conflict(scope) do update set snapshot_id=excluded.snapshot_id;
select is(api.svc_lca_snapshot_candidates('full_library',null,null,1)#>>'{data,0,snapshotId}','87300000-0000-4000-8000-000000000001','current candidate sorts before an obsolete active pointer');
select * from finish();
rollback;
