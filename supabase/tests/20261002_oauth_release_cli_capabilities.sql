begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth;
select no_plan();

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous
) values (
  '00000000-0000-0000-0000-000000000000',
  'a7670000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', 'oauth-release-manager@example.invalid',
  'test-password-hash', now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"sub":"a7670000-0000-4000-8000-000000000001"}'::jsonb,
  now(), now(), false, false
);

insert into private.users (id, raw_user_meta_data, contact)
values (
  'a7670000-0000-4000-8000-000000000001',
  '{"email":"oauth-release-manager@example.invalid"}'::jsonb,
  null
);
insert into private.teams (id, json, rank, is_public)
values ('00000000-0000-0000-0000-000000000000', '{"name":"System Team"}', 0, false)
on conflict (id) do nothing;
insert into private.roles (user_id, team_id, role)
values (
  'a7670000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'data_product_manager'
);

insert into private.lca_network_snapshots (id, scope, status, created_by)
values (
  'a7670000-0000-4000-8000-000000000010',
  'full_library', 'ready', 'a7670000-0000-4000-8000-000000000001'
);
insert into private.worker_jobs (id,job_kind,worker_queue,requester_type,requested_by,status,payload_schema_version,payload_json)
values ('a7670000-0000-4000-8000-000000000020','lca.solve_all_unit','solver','user',
 'a7670000-0000-4000-8000-000000000001','completed','lca.solve_all_unit.request.v1','{}');
insert into private.lca_results (id,job_id,snapshot_id,diagnostics,worker_job_id)
values ('a7670000-0000-4000-8000-000000000030','a7670000-0000-4000-8000-000000000020',
 'a7670000-0000-4000-8000-000000000010','{}','a7670000-0000-4000-8000-000000000020');
create or replace function pg_temp.semantic_downloads()
returns jsonb
language sql
immutable
as $$
  select jsonb_agg(jsonb_build_object(
    'role', item.role,
    'group', item.group_name,
    'fileName', item.file_name,
    'schemaVersion', 'tiangong.calculation-download.v1',
    'mediaType', item.media_type,
    'artifactUrl', 's3://lca_results/downloads/' || item.file_name,
    'sha256', repeat('a', 64),
    'byteSize', 100,
    'recordCount', 10
  ) order by item.ordinal)
  from (values
    (1, 'lcia_results_xlsx', 'results', 'lcia-results.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
    (2, 'lcia_results_csv_zip', 'results', 'lcia-results.csv.zip', 'application/zip'),
    (3, 'lci_inventory_parquet', 'advanced_data', 'lci-inventory.parquet', 'application/vnd.apache.parquet'),
    (4, 'lci_inventory_csv_zip', 'advanced_data', 'lci-inventory-csv.zip', 'application/zip'),
    (5, 'calculation_evidence_bundle', 'audit_evidence', 'calculation-evidence-bundle.zip', 'application/zip')
  ) as item(ordinal, role, group_name, file_name, media_type)
$$;

insert into private.lcia_result_packages (
 id,build_id,build_worker_job_id,package_version,coverage_mode,eligibility_resolved_at,eligible_input_count,included_input_count,
 input_manifest_hash,input_manifest,snapshot_id,result_id,artifact_manifest,created_by)
values ('a7670000-0000-4000-8000-000000000040','a7670000-0000-4000-8000-000000000050',
 'a7670000-0000-4000-8000-000000000020','01.00.000','global_eligible',now(),1,1,repeat('b',64),'{}',
 'a7670000-0000-4000-8000-000000000010','a7670000-0000-4000-8000-000000000030',
 jsonb_build_object('calculationBundle',jsonb_build_object('schemaVersion','tiangong.calculation-bundle.v2',
 'manifestUrl','s3://lca_results/calculation-bundle.json','downloads',pg_temp.semantic_downloads())),
 'a7670000-0000-4000-8000-000000000001');
-- A separate ordinary actor passes the client gate but remains unable to read bundles.
insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
 raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_sso_user,is_anonymous)
values ('00000000-0000-0000-0000-000000000000','a7670000-0000-4000-8000-000000000002',
 'authenticated','authenticated','oauth-release-reader@example.invalid','test-password-hash',now(),
 '{"provider":"email","providers":["email"]}','{}',now(),now(),false,false);
insert into private.users (id,raw_user_meta_data,contact)
values ('a7670000-0000-4000-8000-000000000002','{}',null);

create temporary table cli_release_routes(identity text primary key, name text, anon_allowed boolean, service_allowed boolean);
insert into cli_release_routes values
 ('api.assert_lca_release_manager()','assert_lca_release_manager',false,false),
 ('api.cmd_lca_release_prepare(uuid, text, text, text, jsonb, text, text, jsonb, text, text, jsonb)','cmd_lca_release_prepare',false,false),
 ('api.cmd_lca_release_approve(uuid, text, timestamp with time zone, text, jsonb)','cmd_lca_release_approve',false,false),
 ('api.cmd_lca_release_publish(uuid, uuid, text, text, text, text, text, jsonb)','cmd_lca_release_publish',false,false),
 ('api.cmd_lca_release_readback_verify(uuid, text, jsonb, jsonb)','cmd_lca_release_readback_verify',false,false),
 ('api.cmd_lca_release_unpublish(uuid, text, jsonb)','cmd_lca_release_unpublish',false,false),
 ('api.get_current_lca_release()','get_current_lca_release',true,true),
 ('api.get_lca_release_run(uuid)','get_lca_release_run',false,true),
 ('api.get_lca_release_artifact_download(uuid)','get_lca_release_artifact_download',false,true),
 ('api.get_lcia_result_calculation_bundle(uuid)','get_lcia_result_calculation_bundle',false,false);
grant select on cli_release_routes to authenticated;
select ok((select bool_and(m.capability_id='CLI-RPC-01' and m.allow_authenticated
 and m.allow_anon=r.anon_allowed and m.allow_service_role=r.service_allowed)
 from cli_release_routes r join private.api_capability_grants m on to_regprocedure(m.routine_identity)=to_regprocedure(r.identity)),
 'all exact release routes keep role flags and use existing CLI capability');
select ok((select bool_and(has_function_privilege('authenticated',to_regprocedure(identity),'execute')
 and has_function_privilege('anon',to_regprocedure(identity),'execute')=anon_allowed
 and has_function_privilege('service_role',to_regprocedure(identity),'execute')=service_allowed) from cli_release_routes),
 'release function ACLs retain exact external role boundaries');
select is((select capability_id from private.api_capability_grants where to_regprocedure(routine_identity)=
 'api.get_current_lca_release_process(uuid,text)'::regprocedure),'EDGE-REL-01','untraced process-results route keeps its existing capability');

set local role service_role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select api.svc_oauth_client_configure('test-767-cli','cli',true,
 array['CLI-ALIAS-02','CLI-RPC-01','DB-CORE-READ-01','DB-CORE-WRITE-01','EDGE-BUNDLE-01','NX-CORE-02']);
select api.svc_oauth_client_configure('test-767-mcp','mcp_client',true,
 array['DB-CORE-READ-01','DB-CORE-WRITE-01','EDGE-BUNDLE-01']);
select api.svc_oauth_client_configure('test-767-disabled','cli',false,array['CLI-RPC-01']);
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"a7670000-0000-4000-8000-000000000001","client_id":"test-767-cli"}',true);
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','a7670000-0000-4000-8000-000000000001',true);
select set_config('request.method','POST',true);
select set_config('request.headers','{"content-profile":"api"}',true);
select lives_ok(format('select set_config(''request.path'',''/rpc/%s'',true); select api.oauth_client_pre_request()',name),
 format('official CLI class admits %s before actor authorization',name)) from cli_release_routes order by name;
select set_config('request.path','/rpc/get_lcia_result_calculation_bundle',true);
select lives_ok('select api.oauth_client_pre_request()','real manager bundle path passes OAuth gate');
select is(jsonb_array_length(api.get_lcia_result_calculation_bundle('a7670000-0000-4000-8000-000000000040')->'data'->'productDownloads'),5,
 'admitted manager receives actual five-role Calculation Bundle projection');
select is(api.assert_lca_release_manager()->>'ok','true','admitted manager passes actual manager assertion');
select set_config('request.path','/rpc/get_current_lca_release',true);
select lives_ok('select api.oauth_client_pre_request()','current public release route passes gate');
select is(api.get_current_lca_release()->>'code','publication_not_found','current route reaches real domain read instead of client denial');

select set_config('request.jwt.claims','{"role":"authenticated","sub":"a7670000-0000-4000-8000-000000000002","client_id":"test-767-cli"}',true);
select set_config('request.jwt.claim.sub','a7670000-0000-4000-8000-000000000002',true);
select set_config('request.path','/rpc/get_lcia_result_calculation_bundle',true);
select lives_ok('select api.oauth_client_pre_request()','ordinary actor passes same client gate');
select is(api.get_lcia_result_calculation_bundle('a7670000-0000-4000-8000-000000000040')->>'code','not_data_product_manager',
 'ordinary actor still cannot obtain a Calculation Bundle');
select is(api.assert_lca_release_manager()->>'code','not_data_product_manager','manager assertion still denies ordinary actor');
select is(api.cmd_lca_release_prepare('a7670000-0000-4000-8000-000000000080','01.00.767',repeat('a',64),repeat('b',64),'{}',repeat('c',64),
 repeat('d',64),'{}',repeat('e',64),'test-767-nonmanager','{}')->>'code','not_data_product_manager','release write still rejects ordinary actor');
select set_config('request.path','/rpc/get_current_lca_release_process',true);
select throws_ok('select api.oauth_client_pre_request()','42501','OAuth client is not authorized for this API route',
 'untraced process-results OAuth route remains denied');
select set_config('request.path','/rpc/unknown_release_command',true);
select throws_ok('select api.oauth_client_pre_request()','42501','OAuth client is not authorized for this API route','unknown RPC remains denied');
select set_config('request.path','/processes',true);
select set_config('request.headers','{"content-profile":"public"}',true);
select throws_ok('select api.oauth_client_pre_request()','42501','OAuth client is not authorized for this API route','raw table write remains denied');
select set_config('request.headers','{"content-profile":"api"}',true);

select set_config('request.jwt.claims','{"role":"authenticated","sub":"a7670000-0000-4000-8000-000000000001","client_id":"test-767-mcp"}',true);
select set_config('request.jwt.claim.sub','a7670000-0000-4000-8000-000000000001',true);
select throws_ok(format('select set_config(''request.path'',''/rpc/%s'',true); select api.oauth_client_pre_request()',name),
 '42501','OAuth client is not authorized for this API route',format('MCP class remains denied %s',name)) from cli_release_routes order by name;
select set_config('request.path','/rpc/get_lcia_result_calculation_bundle',true);
select set_config('request.jwt.claims','{"role":"authenticated","client_id":"test-767-disabled"}',true);
select throws_ok('select api.oauth_client_pre_request()','42501','OAuth client is not authorized for this API route','disabled CLI stays denied');
select set_config('request.jwt.claims','{"role":"authenticated","client_id":"test-767-unregistered"}',true);
select throws_ok('select api.oauth_client_pre_request()','42501','OAuth client is not authorized for this API route','unregistered client stays denied');
select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select lives_ok('select api.oauth_client_pre_request()','first-party session without client_id preserves gate bypass');
select is(api.get_lcia_result_calculation_bundle('a7670000-0000-4000-8000-000000000040')->>'ok','true','first-party manager bundle behavior remains unchanged');
reset role;
select ok(not has_function_privilege('authenticated',
 'private.cmd_lca_release_artifacts_finalize_service(uuid,text,jsonb,text,jsonb,jsonb)','execute'),
 'internal service finalize remains inaccessible to authenticated actors');
select ok(not has_table_privilege('authenticated','private.lca_release_runs','insert')
 and not has_table_privilege('authenticated','private.lca_release_publications','insert'),
 'release raw writes remain ACL-closed');
select * from finish();
rollback;
