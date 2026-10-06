#!/usr/bin/env python3
"""Database #777: real Auth/PostgREST identity regression on an owned local stack.

Requires --task-owned-local-stack and project_id database-engine-advisor-777
or an isolated project_id beginning database-engine-777-. Keys are read in memory from `supabase status`; no key,
password, JWT, or RPC response is printed. Auth users are real password-grant
users, not locally forged JWTs. Every fixture has a fresh run-specific UUID.
Fixture creation/deletion suppresses writer/egress and FK triggers
transaction-locally; referenced synthetic parents are explicitly present.
HTTP reads execute the production RPC guards.
"""
from __future__ import annotations

import argparse
import json
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


class Failure(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def command(argv: list[str], *, data: str | None = None) -> str:
    try:
        result = subprocess.run(argv, input=data, text=True, capture_output=True, timeout=90)
    except (OSError, subprocess.TimeoutExpired):
        raise Failure("local command unavailable or timed out") from None
    require(result.returncode == 0, "local command failed (output suppressed)")
    return result.stdout


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(base: str, path: str, key: str, *, token: str | None = None,
            body: dict | None = None, method: str = "POST", api: bool = False) -> tuple[int, object]:
    headers = {"apikey": key, "Authorization": "Bearer " + (token or key),
               "Content-Type": "application/json"}
    if api:
        headers["Content-Profile"] = "api"
        headers["Accept-Profile"] = "api"
    req = urllib.request.Request(base + path, headers=headers, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        # Credentials belong only to the selected loopback stack. urllib's
        # default ProxyHandler would otherwise honor ambient HTTP(S)_PROXY.
        response = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect).open(req, timeout=30)
    except urllib.error.HTTPError as exc:
        response = exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise Failure("local HTTP transport failed") from exc
    with response:
        status = response.code
        raw = response.read()
    try:
        payload = json.loads(raw) if raw else None
    except (ValueError, UnicodeError) as exc:
        raise Failure(f"local HTTP returned invalid JSON (status {status})") from exc
    return status, payload


def sql(container: str, statement: str) -> str:
    return command(["docker", "exec", "-i", container, "psql", "-X", "-qAt",
                    "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"], data=statement)


def checked_uuid(value: object) -> str:
    require(isinstance(value, str), "Auth response has no user identity")
    try:
        return str(uuid.UUID(value))
    except ValueError as exc:
        raise Failure("Auth response identity is invalid") from exc


def run(args: argparse.Namespace) -> None:
    require(args.task_owned_local_stack, "explicit task-owned local-stack acknowledgment required")
    workdir = Path(args.workdir)
    require(workdir.is_absolute(), "workdir must be absolute")
    try:
        config_text = (workdir / "supabase/config.toml").read_text()
    except OSError as exc:
        raise Failure("isolated local config cannot be read") from exc
    # Read only the two fixed scalar identity fields; reject ambiguous shapes.
    # This keeps the probe compatible with the repository's Python 3.9 runtime.
    top_level = re.split(r'^\[', config_text, maxsplit=1, flags=re.M)[0]
    projects = re.findall(r'^project_id\s*=\s*"([^"\n]+)"\s*$', top_level, re.M)
    api_sections = re.findall(r'^\[api\]\s*\n(.*?)(?=^\[|\Z)', config_text, re.M | re.S)
    require(len(projects) == 1 and len(api_sections) == 1, "local project/API config identity is ambiguous")
    ports = re.findall(r'^port\s*=\s*([0-9]+)\s*$', api_sections[0], re.M)
    require(len(ports) == 1, "local API port is ambiguous")
    project = projects[0]
    api_port = int(ports[0])
    require(project == "database-engine-advisor-777"
            or re.fullmatch(r"database-engine-777-[a-z0-9-]+", project) is not None,
            "refusing a stack outside Database #777 ownership")
    container = "supabase_db_" + project
    inspect = json.loads(command(["docker", "inspect", container]))
    require(len(inspect) == 1 and inspect[0]["State"]["Running"], "owned database container is not running")
    values = {}
    status = command([args.supabase_cli, "status", "--workdir", str(workdir), "--output", "env"])
    for line in status.splitlines():
        match = re.fullmatch(r'([A-Z0-9_]+)="(.*)"', line.strip())
        if match:
            values[match[1]] = match[2]
    base = values.get("API_URL", "").rstrip("/")
    url = urllib.parse.urlsplit(base)
    require(url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost", "::1"}
            and not url.username and not url.password and not url.path and not url.query and not url.fragment,
            "refusing a non-loopback API URL")
    require(url.port == api_port, "status API port does not match the owned config")
    kong = json.loads(command(["docker", "inspect", "supabase_kong_" + project]))
    require(len(kong) == 1 and kong[0]["State"]["Running"], "owned API gateway container is not running")
    bindings = kong[0].get("NetworkSettings", {}).get("Ports", {}).get("8000/tcp") or []
    require(any(binding.get("HostPort") == str(api_port) for binding in bindings),
            "loopback API port does not belong to the selected gateway")
    anon = values.get("ANON_KEY", "")
    service = values.get("SERVICE_ROLE_KEY", "")
    require(bool(anon and service), "owned local stack keys are unavailable")
    # The DB identity must agree with the explicitly selected isolated project.
    require(sql(container, "select current_database();").strip() == "postgres", "unexpected local database")
    run_id = uuid.uuid4()
    team, draft, public, marker = [str(uuid.uuid5(run_id, label)) for label in ("team", "draft", "public", "marker")]
    users: list[str] = []
    tokens: dict[str, str] = {}
    registered_emails: list[str] = []
    print("INFO synthetic fixture run: " + run_id.hex)
    failure: Exception | None = None
    try:
        for label in ("owner", "outsider"):
            email = f"issue777-{run_id.hex}-{label}@example.invalid"
            # Own the exact run email before create: a committed creation can
            # outlive a lost/invalid response without returning a usable UUID.
            registered_emails.append(email)
            password = secrets.token_urlsafe(32)
            code, payload = request(base, "/auth/v1/admin/users", service,
                                    body={"email": email, "password": password, "email_confirm": True})
            require(code in {200, 201} and isinstance(payload, dict), f"Auth fixture creation failed (status {code})")
            require(payload.get("email") == email, "Auth fixture response email mismatch")
            user_id = checked_uuid(payload.get("id"))
            users.append(user_id)  # Own the user before any later operation can fail.
            code, payload = request(base, "/auth/v1/token?grant_type=password", anon,
                                    body={"email": email, "password": password})
            require(code == 200 and isinstance(payload, dict), f"real Auth password grant failed (status {code})")
            require(payload.get("user", {}).get("id") == user_id and isinstance(payload.get("access_token"), str),
                    "real Auth token identity mismatch")
            tokens[user_id] = payload["access_token"]
        owner, outsider = users
        document = json.dumps({"issue777Reference": marker})
        # All interpolated values are validated/generated UUIDs or this fixed-shape JSON.
        sql(container, f"""
begin;
set local session_replication_role = replica;
insert into private.users(id,raw_user_meta_data,contact)
values ('{owner}','{{}}',null),('{outsider}','{{}}',null) on conflict(id) do nothing;
insert into private.teams(id,json,rank,is_public) values ('{team}','{{"name":"Issue 777 HTTP fixture"}}',1,false);
insert into private.roles(user_id,team_id,role) values ('{owner}','{team}','owner');
insert into public.processes(id,version,json,json_ordered,user_id,state_code,team_id,search_text,rule_verification,created_at,modified_at)
values ('{draft}','01.00.000','{document}'::jsonb,'{document}'::json,'{owner}',0,'{team}',array['issue777 synthetic'],true,now(),now()),
('{public}','01.00.000','{document}'::jsonb,'{document}'::json,'{owner}',100,'{team}',array['issue777 synthetic'],true,now(),now());
commit;
""")

        def rpc(name: str, body: dict, token: str | None, expected: int, label: str) -> None:
            code, payload = request(base, "/rest/v1/rpc/" + name, anon, token=token, body=body, api=True)
            require(code == 200, f"{label}: unexpected HTTP status {code}")
            require(isinstance(payload, list) and len(payload) == expected, f"{label}: row visibility mismatch")
            if expected:
                allowed_id = public if body.get("data_source") == "tg" else draft
                require(all(row.get("id", row.get("source_id")) == allowed_id for row in payload),
                        f"{label}: wrong fixture identity")
            print("PASS " + label)

        own_args = {"query_text": draft, "data_source": "my", "this_user_id": owner}
        team_args = {"query_text": draft, "data_source": "te", "team_id_filter": team}
        mentions = {"p_uuid": marker, "p_source_entity_kinds": ["process"], "p_data_source": "te",
                    "p_team_id_filter": team, "p_state_code_filter": 0, "p_limit": 20}
        rpc("search_processes", own_args, None, 0, "anonymous parameter spoof refused")
        rpc("search_processes", team_args, None, 0, "anonymous team UUID refused")
        rpc("search_dataset_json_uuid_mentions", mentions, None, 0, "anonymous UUID mentions refused")
        rpc("search_processes", team_args, tokens[outsider], 0, "authenticated outsider team UUID refused")
        rpc("search_dataset_json_uuid_mentions", mentions, tokens[outsider], 0, "authenticated outsider UUID mentions refused")
        rpc("search_processes", own_args, tokens[outsider], 0, "authenticated outsider parameter spoof refused")
        rpc("search_processes", {**own_args, "this_user_id": outsider}, tokens[owner], 1, "owner identity wins over parameter")
        rpc("search_processes", team_args, tokens[owner], 1, "legitimate team owner preserved")
        rpc("search_dataset_json_uuid_mentions", mentions, tokens[owner], 1, "legitimate team UUID mentions preserved")
        rpc("search_processes", {"query_text": public, "data_source": "tg"}, None, 1, "public anonymous exact UUID preserved")
        # Revoke the actual role row and prove readback does not reuse JWT membership.
        sql(container, f"delete from private.roles where user_id='{owner}' and team_id='{team}';")
        rpc("search_processes", team_args, tokens[owner], 0, "membership revocation immediately enforced")
    except Exception as exc:
        failure = exc
    finally:
        cleanup_errors = []
        retained_users: set[str] = set()
        # Only exact emails registered for this run can recover an ambiguous
        # Auth-create response. Never enumerate the Auth directory or other runs.
        emails = "array[" + ",".join("'" + email + "'" for email in registered_emails) + "]::text[]"
        try:
            discovered = json.loads(sql(container, f"select coalesce(jsonb_agg(id::text),'[]'::jsonb) from auth.users where email = any({emails});"))
            require(isinstance(discovered, list), "owned Auth identity recovery is malformed")
            users = sorted(set(users) | {checked_uuid(value) for value in discovered})
        except Exception:
            cleanup_errors.append("exact run-email Auth identity recovery failed")
        try:
            sql(container, f"""begin; set local session_replication_role=replica;
delete from public.processes where id in ('{draft}','{public}');
delete from private.roles where team_id='{team}';
delete from private.teams where id='{team}'; commit;""")
        except Exception:
            cleanup_errors.append("SQL fixture cleanup failed")
        # Revoke known sessions/refresh tokens before deleting our synthetic
        # users. GoTrue access JWTs can remain cryptographically valid until exp;
        # subsequent SQL cleanup removes every resource bound to these actors.
        for user in users:
            try:
                # A known UUID whose email was externally changed is no longer
                # a verified member of our cleanup scope. Retain it and fail.
                wrong_owner = sql(container, f"select count(*) from auth.users where id='{user}' and (email is null or not(email = any({emails})));")
                require(wrong_owner.strip() == "0", "Auth fixture email ownership drifted")
                token = tokens.get(user)
                if token is not None:
                    code, _ = request(base, "/auth/v1/logout?scope=global", anon,
                                      token=token, body={})
                    require(code in {200, 204}, f"Auth fixture sign-out failed (status {code})")
                # No token is available after an ambiguous password-grant
                # response. Delete only if the exact user has no live session
                # or refresh grant; otherwise retain it for explicit recovery.
                live_sessions = sql(container, f"""select
(select count(*) from auth.sessions where user_id='{user}') +
(select count(*) from auth.refresh_tokens where user_id::text='{user}' and revoked is distinct from true);""")
                require(live_sessions.strip() == "0", "Auth fixture still has live sessions or refresh grants")
            except Exception:
                retained_users.add(user)
                cleanup_errors.append("Auth session/ownership verification failed; synthetic user retained")
                continue  # Never delete an actor after failed session revocation.
            try:
                code, _ = request(base, "/auth/v1/admin/users/" + user, service, method="DELETE")
                require(code in {200, 204}, f"Auth fixture deletion failed (status {code})")
            except Exception:
                retained_users.add(user)
                cleanup_errors.append("Auth fixture cleanup failed")
        ids = "array[" + ",".join("'" + user + "'" for user in users) + "]::uuid[]"
        try:
            sql(container, f"delete from private.users profile where profile.id = any({ids}) and not exists(select 1 from auth.users actor where actor.id=profile.id);")
            residual = sql(container, f"""select
(select count(*) from public.processes where id in ('{draft}','{public}')) +
(select count(*) from private.teams where id='{team}') +
(select count(*) from private.roles where team_id='{team}' or user_id = any({ids})) +
(select count(*) from private.users where id = any({ids})) +
(select count(*) from auth.users where id = any({ids}) or email = any({emails})) +
(select count(*) from auth.identities where user_id = any({ids})) +
(select count(*) from auth.sessions where user_id = any({ids})) +
(select count(*) from auth.refresh_tokens where user_id::text = any({ids}::text[]));""")
            require(residual.strip() == "0", "synthetic fixture residuals remain")
        except Exception:
            cleanup_errors.append("fixture residual verification failed")
        if cleanup_errors:
            print("FAIL cleanup receipt: incomplete; synthetic run " + run_id.hex
                  + "; retained/uncertain user IDs " + ",".join(sorted(retained_users)), file=sys.stderr)
            raise Failure("; ".join(cleanup_errors)) from failure
        print("PASS cleanup receipt: exact run emails and known IDs have zero synthetic users, sessions, refresh grants, identities and database fixtures")
    if failure:
        raise failure


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True, help="absolute owned isolated Supabase project directory")
    parser.add_argument("--task-owned-local-stack", action="store_true")
    parser.add_argument("--supabase-cli", default="supabase")
    args = parser.parse_args()
    try:
        run(args)
    except Failure as exc:
        print("FAIL " + str(exc), file=sys.stderr)
        return 1
    except Exception:
        print("FAIL unexpected local probe error (details suppressed)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
