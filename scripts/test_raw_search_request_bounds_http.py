#!/usr/bin/env python3
"""Database #793: raw bounds through real local Auth and PostgREST.

Run only on the explicitly owned database-engine-793 stack after its scheduled
reset. Reuses the existing credential-safe local transport helpers. Creates one
real Auth user and deletes it in finally; creates no dataset or DB fixture.
Credentials and response payloads stay in memory and never enter stdout.
"""
from __future__ import annotations

import argparse
import json
import re
import secrets
import sys
import urllib.parse
import uuid
from pathlib import Path

from test_search_request_identity_http import (
    Failure, checked_uuid, command, request, require, sql,
)


FAMILIES = ("contacts", "flowproperties", "flows", "lifecyclemodels", "processes", "sources", "unitgroups")
TARGETS = tuple(("hybrid_search_" + name + suffix, True) for name in FAMILIES for suffix in ("", "_v2")) + tuple(
    ("search_" + name + suffix, False) for name in FAMILIES for suffix in ("", "_latest")
) + (("search_processes_latest_v2", False),)


def rehearse_upgrade_authority(container: str) -> None:
    """Rollback three states on the real production-class postgres login."""
    require(sql(container, "select session_user='postgres' and current_user='postgres' and not rolsuper and rolcreaterole from pg_catalog.pg_roles where rolname=current_user;").strip() == "t",
            "authority rehearsal requires real NOSUPERUSER/CREATEROLE postgres session")
    require(sql(container, "select count(*) from pg_catalog.pg_auth_members m where m.roleid='api_internal_executor'::regrole and m.member='postgres'::regrole and m.grantor='supabase_admin'::regrole and m.admin_option and not m.inherit_option and not m.set_option;").strip() == "1",
            "production-class external admin membership missing")
    repo = Path(__file__).resolve().parents[1]
    migration = (repo / "supabase/migrations/20261007142623_raw_search_request_bounds.sql").read_text()
    require(len(re.findall(r"^begin;$", migration, re.M)) == 1
            and migration.endswith("commit;\n"), "migration transaction shape drifted")
    migration = re.sub(r"^begin;\n", "", migration, count=1, flags=re.M)
    migration = re.sub(r"^commit;\s*$", "", migration, count=1, flags=re.M)
    tests = (repo / "supabase/tests/20261007_raw_search_request_bounds.sql").read_text()
    first = tests.index('CREATE OR REPLACE FUNCTION "pg_temp"."raw793_before_')
    last = tests.index("create function pg_temp.raw793_outcome(")
    originals = tests[first:last]
    require(originals.count('CREATE OR REPLACE FUNCTION "pg_temp".') == 29, "original facade set drifted")
    originals = re.sub(r'"pg_temp"\."raw793_before_([a-z_0-9]+)"', r'"api"."\1"', originals)
    originals = re.sub(r"^grant execute on function .*;\n", "", originals, flags=re.M)
    originals = originals.replace("pg_temp.raw793_before_", "api.")
    for state in ("own-grant-absent", "own-grant-set-false", "own-grant-set-true-create-present"):
        own = ""
        if state == "own-grant-set-false":
            own = "grant api_internal_executor to postgres with admin false,inherit false,set false;\n"
        if state == "own-grant-set-true-create-present":
            own = ("grant api_internal_executor to postgres with admin false,inherit true,set true;\n"
                   "grant create on schema api to api_internal_executor;\n")
        statement = f"""begin;
set local lock_timeout='5s';
set local statement_timeout='60s';
create temp table authority_external_before on commit drop as
select m.* from pg_catalog.pg_auth_members m where m.roleid='api_internal_executor'::regrole and m.member='postgres'::regrole and m.grantor='supabase_admin'::regrole;
-- Restore only old API bodies inside this rollback transaction. Existing
-- private retrieval implementations and data remain unchanged.
grant api_internal_executor to postgres with inherit false,set true;
grant create on schema api to api_internal_executor;
set local role api_internal_executor;
{originals}
reset role;
revoke create on schema api from api_internal_executor;
revoke api_internal_executor from postgres;
{own}
create temp table authority_probe_before on commit drop as
select m.* from pg_catalog.pg_auth_members m where m.roleid='api_internal_executor'::regrole and m.member='postgres'::regrole;
create temp table authority_schema_before on commit drop as
select oid,nspacl from pg_catalog.pg_namespace where oid='api'::regnamespace;
do $probe$
begin
 if session_user<>'postgres' or current_user<>'postgres'
  or (select rolsuper or not rolcreaterole from pg_catalog.pg_roles where rolname=current_user) then
  raise exception 'non-superuser migration session drift';
 end if;
end;
$probe$;
{migration}
do $verify$
begin
 if exists((select * from authority_probe_before except select m.* from pg_catalog.pg_auth_members m where m.roleid='api_internal_executor'::regrole and m.member='postgres'::regrole)
 union all(select m.* from pg_catalog.pg_auth_members m where m.roleid='api_internal_executor'::regrole and m.member='postgres'::regrole except select * from authority_probe_before))
 or exists(select 1 from authority_schema_before b join pg_catalog.pg_namespace n using(oid) where n.nspacl is distinct from b.nspacl)
 or exists((select * from authority_external_before except select m.* from pg_catalog.pg_auth_members m where m.roleid='api_internal_executor'::regrole and m.member='postgres'::regrole and m.grantor='supabase_admin'::regrole)
 union all(select m.* from pg_catalog.pg_auth_members m where m.roleid='api_internal_executor'::regrole and m.member='postgres'::regrole and m.grantor='supabase_admin'::regrole except select * from authority_external_before)) then
  raise exception 'authority upgrade fixture did not restore';
 end if;
 if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='api' and p.prosrc like '%raw793 bounds end.%')<>29 then
  raise exception 'authority upgrade facade set incomplete';
 end if;
end;
$verify$;
rollback;
"""
        sql(container, statement)
        print("PASS rollback real postgres authority: " + state + "; exact member OIDs/options/grantors and api ACL restored")


def run(args: argparse.Namespace) -> None:
    require(args.task_owned_local_stack, "explicit task-owned stack acknowledgment required")
    workdir = Path(args.workdir)
    require(workdir.is_absolute(), "workdir must be absolute")
    config = (workdir / "supabase/config.toml").read_text()
    top = re.split(r"^\[", config, maxsplit=1, flags=re.M)[0]
    projects = re.findall(r'^project_id\s*=\s*"([^"\n]+)"\s*$', top, re.M)
    sections = re.findall(r"^\[api\]\s*\n(.*?)(?=^\[|\Z)", config, re.M | re.S)
    require(projects == ["database-engine-793"] and len(sections) == 1,
            "refusing a stack outside Database #793 ownership")
    ports = re.findall(r"^port\s*=\s*([0-9]+)\s*$", sections[0], re.M)
    require(len(ports) == 1, "ambiguous owned API port")
    port = int(ports[0])
    container = "supabase_db_database-engine-793"
    db = json.loads(command(["docker", "inspect", container]))
    require(len(db) == 1 and db[0]["State"]["Running"], "owned DB is not running")
    values = {}
    for line in command([args.supabase_cli, "status", "--workdir", str(workdir), "--output", "env"]).splitlines():
        match = re.fullmatch(r'([A-Z0-9_]+)="(.*)"', line.strip())
        if match:
            values[match[1]] = match[2]
    base = values.get("API_URL", "").rstrip("/")
    url = urllib.parse.urlsplit(base)
    require(url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost", "::1"}
            and url.port == port and not any((url.username, url.password, url.path, url.query, url.fragment)),
            "refusing non-owned or non-loopback API")
    kong = json.loads(command(["docker", "inspect", "supabase_kong_database-engine-793"]))
    require(len(kong) == 1 and kong[0]["State"]["Running"], "owned gateway is not running")
    bindings = kong[0].get("NetworkSettings", {}).get("Ports", {}).get("8000/tcp") or []
    require(any(binding.get("HostPort") == str(port) for binding in bindings), "API port ownership mismatch")
    anon, service = values.get("ANON_KEY", ""), values.get("SERVICE_ROLE_KEY", "")
    require(bool(anon and service), "owned stack keys unavailable")
    if args.upgrade_authority_only:
        rehearse_upgrade_authority(container)
        return
    run_id = uuid.uuid4().hex
    email = "raw793-" + run_id + "@example.invalid"
    user_id = None
    token = None
    created = False
    checks = 0
    print("INFO owned Auth fixture run: " + run_id)
    try:
        created = True  # Own exact email before any possible lost create response.
        password = secrets.token_urlsafe(32)
        code, payload = request(base, "/auth/v1/admin/users", service,
                                body={"email": email, "password": password, "email_confirm": True})
        require(code in {200, 201} and isinstance(payload, dict) and payload.get("email") == email,
                "real Auth fixture creation failed")
        user_id = checked_uuid(payload.get("id"))
        code, payload = request(base, "/auth/v1/token?grant_type=password", anon,
                                body={"email": email, "password": password})
        require(code == 200 and isinstance(payload, dict) and payload.get("user", {}).get("id") == user_id
                and isinstance(payload.get("access_token"), str), "real Auth token verification failed")
        token = payload["access_token"]
        vector = "[1," + ",".join(["0"] * 1023) + "]"
        query = str(uuid.uuid4())
        for role, credential in (("anon", None), ("authenticated", token)):
            for name, hybrid in TARGETS:
                body = {"query_text": query, "data_source": "my"}
                if hybrid:
                    body["query_embedding"] = vector
                cap = 100 if hybrid else 1000
                invalid = [("page_size", cap + 1), ("page_size", 2147483647), ("page_current", 2147483647)]
                if hybrid:
                    invalid += [("match_count", 101), ("match_count", 2147483647)]
                elif "_latest" in name:
                    invalid += [("page_size", 9223372036854775807), ("page_current", 9223372036854775807)]
                for field, value in invalid:
                    oversized = {**body, field: value}
                    if hybrid:
                        oversized["query_embedding"] = "invalid vector"
                    code, payload = request(base, "/rest/v1/rpc/" + name, anon,
                                            token=credential, body=oversized, api=True)
                    require(code == 400 and isinstance(payload, dict) and payload.get("code") == "22023",
                            f"{role} {name} {field}: expected early HTTP 400/22023")
                    checks += 1
                for options in ({}, {"page_size": None, "page_current": None},
                                {"page_size": 0, "page_current": -1}, {"page_size": cap},
                                {"page_size": 1, "page_current": 2147483647}):
                    code, payload = request(base, "/rest/v1/rpc/" + name, anon,
                                            token=credential, body={**body, **options}, api=True)
                    require(code == 200 and payload == [], f"{role} {name}: default/NULL/lower/edge semantics changed")
                    checks += 1
            print(f"PASS {role}: all 29 raw facades reject oversized requests and retain normalized edges")
        # Service exposure stays whatever the exact capability manifest permits.
        for name in ("search_flows", "hybrid_search_processes"):
            allowed = sql(container, "select allow_service_role from private.api_capability_grants where split_part(routine_identity,'(',1)='api."
                          + name + "';").strip()
            require(allowed in {"t", "f"}, "ambiguous service capability manifest")
            body = {"query_text": query, "page_size": 1001}
            if name.startswith("hybrid_"):
                body["query_embedding"] = "invalid vector"
            code, payload = request(base, "/rest/v1/rpc/" + name, service, body=body, api=True)
            require(isinstance(payload, dict) and payload.get("code") == ("22023" if allowed == "t" else "42501"),
                    "service-role API exposure changed")
            checks += 1
        code, payload = request(base, "/rest/v1/rpc/search_flows", anon,
                                body={"query_text": query}, profile="public")
        require(code in {404, 406} and isinstance(payload, dict) and payload.get("code") in {"PGRST202", "PGRST106"},
                "retired public RPC route reopened")
        checks += 1
        print(f"PASS real Auth/PostgREST bounds: {checks} checks; no datasets created")
    finally:
        if created:
            errors = []
            users = {user_id} if user_id else set()
            # A committed create can outlive a lost response. Resolve only this
            # run's exact email, even when a UUID was previously returned.
            try:
                found = json.loads(sql(container, "select coalesce(jsonb_agg(id::text),'[]'::jsonb) from auth.users where email='" + email + "';"))
                require(isinstance(found, list) and len(found) <= 1, "ambiguous exact-email Auth recovery")
                users.update(checked_uuid(value) for value in found)
            except Exception:
                errors.append("exact-email Auth recovery failed")
            for owned_id in sorted(users):
                try:
                    drift = sql(container, "select count(*) from auth.users where id='" + owned_id
                                + "' and (email is null or email<>'" + email + "');").strip()
                    require(drift == "0", "Auth fixture email ownership drifted")
                    if owned_id == user_id and token is not None:
                        code, _ = request(base, "/auth/v1/logout?scope=global", anon, token=token, body={})
                        require(code in {200, 204}, "Auth fixture sign-out failed")
                    code, _ = request(base, "/auth/v1/admin/users/" + owned_id, service, method="DELETE")
                    require(code in {200, 204, 404}, "Auth fixture deletion failed")
                except Exception:
                    errors.append("Auth fixture session/deletion cleanup failed")
            try:
                ids = "array[" + ",".join("'" + owned_id + "'" for owned_id in sorted(users)) + "]::uuid[]"
                # Auth's deferred delete mirror must remove private.users too;
                # do not hide a broken mirror with a manual profile deletion.
                residual = sql(container, "select "
                               + "(select count(*) from auth.users where email='" + email + "' or id=any(" + ids + "))+"
                               + "(select count(*) from private.users where id=any(" + ids + "))+"
                               + "(select count(*) from auth.identities where user_id=any(" + ids + "))+"
                               + "(select count(*) from auth.sessions where user_id=any(" + ids + "))+"
                               + "(select count(*) from auth.refresh_tokens where user_id::text=any(" + ids + "::text[]));").strip()
                require(residual == "0", "Auth/profile/session fixture residuals remain")
            except Exception:
                errors.append("Auth/profile/session residual verification failed")
            require(not errors, "; ".join(errors) + "; owned fixture run " + run_id)
            print("PASS cleanup: exact-email Auth users, private profiles, identities, sessions and refresh grants are absent")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--supabase-cli", required=True)
    parser.add_argument("--task-owned-local-stack", action="store_true")
    parser.add_argument("--upgrade-authority-only", action="store_true", help="rollback three non-superuser migration authority states without Auth fixtures")
    args = parser.parse_args()
    try:
        run(args)
    except (Failure, OSError, ValueError) as exc:
        print("FAIL " + (str(exc) if isinstance(exc, Failure) else "local fixture/configuration failure"), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
