-- Database #777: rollback-only request identity regression. Run as postgres in
-- an owned disposable database. The two production helper ACLs stay unchanged.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, api, private, auth;
select no_plan();

select ok(not has_function_privilege('anon', 'private.dataset_search_effective_user_id(text)', 'execute'), 'anon cannot call the private identity helper');
select ok(not has_function_privilege('authenticated', 'private.dataset_search_can_read_team_filter(uuid,uuid)', 'execute'), 'authenticated cannot call the private membership helper');

-- Synthetic fixtures bypass writer/egress and FK triggers only within this
-- transaction; non-trigger constraints and indexes stay active. Public RPC
-- execution uses real guards. Every referenced synthetic parent is inserted.
set local session_replication_role = replica;
insert into auth.users(id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous)
values
 ('77700000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','issue777-owner@example.invalid','x',now(),'{}','{}',now(),now(),false,false),
 ('77700000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','issue777-outsider@example.invalid','x',now(),'{}','{}',now(),now(),false,false);
insert into private.users(id,raw_user_meta_data,contact) values
 ('77700000-0000-4000-8000-000000000001','{}',null),
 ('77700000-0000-4000-8000-000000000002','{}',null);
insert into private.teams(id,json,rank,is_public) values
 ('77700000-0000-4000-8000-000000000003','{"name":"Issue 777 synthetic team"}',1,false);
insert into private.roles(user_id,team_id,role) values
 ('77700000-0000-4000-8000-000000000001','77700000-0000-4000-8000-000000000003','owner');
insert into public.processes(id,version,json,json_ordered,user_id,state_code,team_id,search_text,rule_verification,created_at,modified_at)
select id::uuid,'01.00.000',document,document::json,
 '77700000-0000-4000-8000-000000000001',state_code,
 '77700000-0000-4000-8000-000000000003',array['issue777 synthetic'],true,now(),now()
from (values
 ('77700000-0000-4000-8000-000000000010',0),
 ('77700000-0000-4000-8000-000000000011',100),
 ('77700000-0000-4000-8000-000000000012',200),
 ('77700000-0000-4000-8000-000000000013',-1)
) as fixture(id,state_code)
cross join lateral (select jsonb_build_object('issue777Reference','77700000-0000-4000-8000-000000000099') as document) as payload;
set local session_replication_role = origin;

-- PostgreSQL current_user changes twice here; the standard role GUC must not.
create function pg_temp.issue777_inner(p_user text, p_actor uuid)
returns jsonb language sql security definer set search_path = '' as $$
 select pg_catalog.jsonb_build_object(
   'uid', private.dataset_search_effective_user_id(p_user),
   'member', private.dataset_search_can_read_team_filter('77700000-0000-4000-8000-000000000003',p_actor),
   'role', pg_catalog.current_setting('role',true), 'executionUser', current_user)
$$;
create function pg_temp.issue777_probe(p_user text default '77700000-0000-4000-8000-000000000001', p_actor uuid default null)
returns jsonb language sql security definer set search_path = '' as $$
 select pg_temp.issue777_inner(p_user,p_actor)
$$;
create role issue777_unknown nologin;
-- Hosted-compatible postgres has CREATEROLE but is not a superuser. Explicit
-- SET membership admits this one test role; role and membership both roll back.
grant issue777_unknown to postgres with set true;
grant execute on function pg_temp.issue777_probe(text,uuid) to anon, authenticated, service_role, issue777_unknown;
do $$ begin execute format('grant usage on schema %I to anon,authenticated,service_role,issue777_unknown',pg_my_temp_schema()::regnamespace); end $$;

select set_config('request.jwt.claim.role','',true);
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
select is(pg_temp.issue777_probe()->>'role','anon','role GUC survives nested postgres definers');
select is(pg_temp.issue777_probe()->>'executionUser','postgres','probe actually executes with postgres privileges');
select is(pg_temp.issue777_probe()->>'uid',null::text,'JSON-only anonymous cannot impersonate the parameter user');
select is(pg_temp.issue777_probe()->>'member','false','JSON-only anonymous cannot select an arbitrary team');
select is((select count(*) from api.search_processes('77700000-0000-4000-8000-000000000010',data_source=>'my',this_user_id=>'77700000-0000-4000-8000-000000000001')),0::bigint,'anonymous lexical exact UUID cannot read an owner draft');
select is((select count(*) from api.search_dataset_json_uuid_mentions('77700000-0000-4000-8000-000000000099',array['process'],'te','', '77700000-0000-4000-8000-000000000003',0)),0::bigint,'anonymous UUID mentions cannot read team drafts');
select is((select count(*) from api.search_processes('77700000-0000-4000-8000-000000000011',data_source=>'tg')),1::bigint,'anonymous public state 100 remains readable');
select is((select count(*) from api.search_processes('77700000-0000-4000-8000-000000000012',data_source=>'co')),1::bigint,'anonymous public state 200 remains readable');
select set_config('request.jwt.claim.role','service_role',true);
select is(pg_temp.issue777_probe()->>'member','false','legacy service claim cannot elevate actual anon role');
select is(pg_temp.issue777_probe()->>'uid',null::text,'legacy service claim cannot enable anonymous parameter identity');

reset role;
select set_config('request.jwt.claim.role','',true);
select set_config('request.jwt.claims','{"role":"authenticated","sub":"77700000-0000-4000-8000-000000000002"}',true);
set local role authenticated;
select is(pg_temp.issue777_probe()->>'uid','77700000-0000-4000-8000-000000000002','JSON-only authenticated identity ignores a different parameter user');
select is(pg_temp.issue777_probe('', '77700000-0000-4000-8000-000000000002')->>'member','false','JSON-only authenticated outsider is not a team member');
select is(pg_temp.issue777_probe('', '77700000-0000-4000-8000-000000000001')->>'member','false','authenticated outsider cannot spoof the helper member actor');
select is((select count(*) from api.search_processes('77700000-0000-4000-8000-000000000010',data_source=>'te',team_id_filter=>'77700000-0000-4000-8000-000000000003')),0::bigint,'authenticated outsider lexical UUID cannot read team draft');
select is((select count(*) from api.search_dataset_json_uuid_mentions('77700000-0000-4000-8000-000000000099',array['process'],'te','', '77700000-0000-4000-8000-000000000003',0)),0::bigint,'authenticated outsider UUID mentions cannot read team drafts');
select set_config('request.jwt.claim.role','service_role',true);
select is(pg_temp.issue777_probe('', '77700000-0000-4000-8000-000000000002')->>'member','false','legacy service claim cannot elevate authenticated outsider');
select set_config('request.jwt.claim.role','',true);
select set_config('request.jwt.claims','{"role":"authenticated"}',true);
select is(pg_temp.issue777_probe()->>'uid',null::text,'authenticated without sub cannot fall back to parameter user');
select is(pg_temp.issue777_probe()->>'member','false','authenticated without sub has no team authority');
select set_config('request.jwt.claims','{"role":"authenticated","sub":"not-a-uuid"}',true);
select is(pg_temp.issue777_probe()->>'uid',null::text,'malformed JSON sub fails closed without parameter fallback');
select is(pg_temp.issue777_probe('', '77700000-0000-4000-8000-000000000001')->>'member','false','malformed JSON sub cannot claim a valid member actor');
select set_config('request.jwt.claims','{broken-json',true);
select is(pg_temp.issue777_probe()->>'uid',null::text,'malformed JWT claims JSON fails closed');
select is(pg_temp.issue777_probe('', '77700000-0000-4000-8000-000000000001')->>'member','false','malformed JWT claims JSON cannot claim a member actor');
select set_config('request.jwt.claims','{"role":"authenticated","sub":"77700000-0000-4000-8000-000000000001"}',true);
select set_config('request.jwt.claim.sub','not-a-uuid',true);
select is(pg_temp.issue777_probe()->>'uid',null::text,'malformed legacy sub fails closed rather than elevating a parameter identity');
select set_config('request.jwt.claim.sub','',true);
select is(pg_temp.issue777_probe('', '77700000-0000-4000-8000-000000000001')->>'member','true','legitimate team owner retains membership access');
select is((select count(*) from api.search_processes('77700000-0000-4000-8000-000000000010',data_source=>'my',this_user_id=>'77700000-0000-4000-8000-000000000002')),1::bigint,'owner draft read retains actor identity despite conflicting parameter');
select is((select count(*) from api.search_processes('77700000-0000-4000-8000-000000000013',data_source=>'ex')),1::bigint,'authenticated example scope remains readable');

reset role;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
set local role service_role;
select is(pg_temp.issue777_probe()->>'uid','77700000-0000-4000-8000-000000000001','explicit service role retains parameter fallback');
select is(pg_temp.issue777_probe()->>'member','true','explicit service role retains trusted team path');
select set_config('request.jwt.claims','{"role":"service_role","sub":"77700000-0000-4000-8000-000000000002"}',true);
select is(pg_temp.issue777_probe()->>'uid','77700000-0000-4000-8000-000000000002','explicit service role retains actor-first identity over parameter fallback');
select set_config('request.jwt.claims','',true);
select is(pg_temp.issue777_probe()->>'member','true','real SQL SET ROLE service_role works without JWT');
reset role;
select set_config('request.jwt.claims','',true);
select set_config('request.jwt.claim.role','',true);
select set_config('request.jwt.claim.sub','',true);
select set_config('request.headers','',true);
select set_config('request.path','',true);
select set_config('request.method','',true);
select is(pg_temp.issue777_probe()->>'uid','77700000-0000-4000-8000-000000000001','postgres role NONE without request context retains SQL parameter fallback');
select is(pg_temp.issue777_probe()->>'member','true','postgres role NONE without request context retains trusted team path');
select set_config('request.jwt.claims','{"role":"anon"}',true);
select is(pg_temp.issue777_probe()->>'member','false','role NONE with request identity is not the trusted SQL path');
select set_config('request.jwt.claims','',true);
select set_config('request.jwt.claim.role','service_role',true);
select is(pg_temp.issue777_probe()->>'member','false','role NONE with legacy request identity is not trusted SQL');
select set_config('request.jwt.claim.role','',true);
select set_config('request.path','/rpc/search_processes',true);
select is(pg_temp.issue777_probe()->>'member','false','role NONE with HTTP request path is not trusted SQL');
select set_config('request.path','',true);
set local role issue777_unknown;
-- This role deliberately has no extensions-schema usage. Materialize probes
-- while its actual role is active, then evaluate TAP as postgres; do not grant
-- extra schema privileges merely to make assertions executable.
select set_config('issue777.unknown_probe',pg_temp.issue777_probe()::text,true);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select set_config('issue777.unknown_service_probe',pg_temp.issue777_probe()::text,true);
reset role;
select is(current_setting('issue777.unknown_probe')::jsonb->>'uid',null::text,'unknown actual role has no parameter identity fallback');
select is(current_setting('issue777.unknown_probe')::jsonb->>'member','false','unknown actual role is not trusted');
select is(current_setting('issue777.unknown_service_probe')::jsonb->>'member','false','unknown actual role cannot elevate through a JSON service claim');
select ok(not has_function_privilege('anon', 'private.dataset_search_effective_user_id(text)', 'execute'), 'private helper ACL stays closed after probes');
select * from finish();
rollback;
