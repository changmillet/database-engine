#!/usr/bin/env python3
"""Standard-library fault tests for the owned-local HTTP probe's cleanup boundary.

No Docker, database, HTTP server, credentials, or filesystem fixture is used.
The fake services record external actions and retain a foreign-run Auth user,
so tests assert recovery/retention behavior rather than implementation strings.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import unittest
import urllib.request
import urllib.response
import uuid
from unittest.mock import patch

import test_search_request_identity_http as probe


class FakeConfigPath:
    def __init__(self, project: str):
        self.project = project

    def is_absolute(self):
        return True

    def __truediv__(self, other):
        return self

    def read_text(self):
        return (f'project_id = "{self.project}"\n[api]\nport = 57321\n'
                '[remotes.dev]\nproject_id = "foreign-remote-project"\n')


class LocalServices:
    """Minimal external Auth/SQL contracts, with explicit run-scoped ownership."""
    foreign_email = "another-task@example.invalid"
    foreign_id = "aaaaaaaa-0000-4000-8000-000000000001"

    def __init__(self, fault: str):
        self.fault = fault
        self.actions = []
        self.registry = {self.foreign_email: self.foreign_id}
        self.created_emails = []
        self.active_sessions = set()
        self.tokens = {}
        self.discovery_scopes = []
        self.residual_scopes = []
        self.output = io.StringIO()

    def command(self, argv, **kwargs):
        self.actions.append(("command", argv))
        if argv[:2] == ["docker", "inspect"]:
            return json.dumps([{"State": {"Running": True}, "NetworkSettings": {
                "Ports": {"8000/tcp": [{"HostPort": "57321"}]}}}])
        return ('API_URL="http://127.0.0.1:57321"\n'
                'ANON_KEY="fake-anon"\nSERVICE_ROLE_KEY="fake-service"')

    @staticmethod
    def emails_in(statement):
        return set(re.findall(r"'(issue777-[0-9a-f]{32}-(?:owner|outsider)@example\.invalid)'", statement))

    def sql(self, container, statement):
        self.actions.append(("sql", statement))
        if re.search(r"delete\s+from\s+auth\.", statement, re.I):
            raise AssertionError("the probe must not bypass Auth cleanup by SQL-deleting users")
        if "current_database()" in statement:
            return "postgres"
        if "jsonb_agg" in statement:
            scope = self.emails_in(statement)
            self.discovery_scopes.append(scope)
            if scope != set(self.created_emails):
                raise AssertionError("identity recovery must bind only exact attempted run emails")
            if self.fault == "recovery_unknown":
                raise probe.Failure("mock identity recovery unavailable")
            return json.dumps([user for email, user in self.registry.items() if email in scope])
        if "email is null" in statement:
            user = re.search(r"where id='([^']+)'", statement).group(1)
            email = next((email for email, candidate in self.registry.items() if candidate == user), None)
            return "0" if email is None or email in self.emails_in(statement) else "1"
        if "revoked is distinct from true" in statement:
            user = re.search(r"user_id='([^']+)'", statement).group(1)
            return "1" if user in self.active_sessions else "0"
        if statement.startswith("select\n"):
            scope = self.emails_in(statement)
            self.residual_scopes.append(scope)
            # A lost creation response must remain detectable by exact email,
            # even when the probe never obtained a known user UUID.
            return str(sum(email in scope for email in self.registry))
        return ""

    def request(self, base, path, key, **kwargs):
        method = kwargs.get("method", "POST")
        self.actions.append(("http", method, path))
        if path == "/auth/v1/admin/users":
            email = kwargs["body"]["email"]
            self.created_emails.append(email)
            user = str(uuid.uuid5(uuid.NAMESPACE_URL, email))
            self.registry[email] = user
            if self.fault in {"create_lost", "recovery_unknown"}:
                raise probe.Failure("mock committed creation response lost")
            return 200, {"id": "invalid-id" if self.fault == "bad_id" else user, "email": email}
        if path.startswith("/auth/v1/token"):
            user = self.registry[kwargs["body"]["email"]]
            self.active_sessions.add(user)
            if self.fault == "grant_lost":
                raise probe.Failure("mock committed password-grant response lost")
            token = "fake-token-" + user
            self.tokens[token] = user
            return 200, {"user": {"id": user}, "access_token": token}
        if path.startswith("/auth/v1/logout"):
            if self.fault == "logout_failed":
                return 500, {}
            self.active_sessions.discard(self.tokens[kwargs["token"]])
            return 204, None
        if path.startswith("/auth/v1/admin/users/"):
            user = path.rsplit("/", 1)[1]
            if user == self.foreign_id or user in self.active_sessions:
                raise AssertionError("foreign or unrevoked user deletion attempted")
            for email in list(self.registry):
                if self.registry[email] == user:
                    del self.registry[email]
            return 200, {}
        # Stop at the first RPC; these unit tests examine cleanup, while the
        # real local-stack script separately proves database visibility.
        return 503, {}

    def run(self, *, acknowledged=True, project="database-engine-advisor-777"):
        args = argparse.Namespace(task_owned_local_stack=acknowledged,
                                  workdir="/fake-owned", supabase_cli="fake-cli")
        with patch.object(probe, "Path", lambda value: FakeConfigPath(project)), \
                patch.object(probe, "command", self.command), \
                patch.object(probe, "sql", self.sql), \
                patch.object(probe, "request", self.request), \
                contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            try:
                probe.run(args)
            except probe.Failure as exc:
                return exc
        raise AssertionError("fault injection unexpectedly completed successfully")

    def deletions(self):
        return [action for action in self.actions if action[:2] == ("http", "DELETE")]


class CleanupContractTests(unittest.TestCase):
    def test_real_urllib_chain_never_routes_loopback_credentials_via_environment_proxy(self):
        transports = []

        def local_transport(handler, req):
            # This replaces the HTTP transport before sockets/connections exist;
            # the real urllib opener/proxy/error/redirect chain still runs.
            transports.append((req.host, req.full_url, req.get_header("Authorization"), req.data))
            response = urllib.response.addinfourl(io.BytesIO(b"{}"), {}, req.full_url, 200)
            response.msg = "OK"
            return response

        environment = {"http_proxy": "http://credential-leak.invalid:8080",
                       "https_proxy": "http://credential-leak.invalid:8080",
                       "no_proxy": "", "NO_PROXY": ""}
        with patch.dict(os.environ, environment, clear=True), \
                patch.object(urllib.request, "proxy_bypass", return_value=False), \
                patch.object(urllib.request.HTTPHandler, "http_open", local_transport):
            code, payload = probe.request("http://127.0.0.1:57321", "/auth/v1/token", "fake-apikey",
                                          token="fake-jwt", body={"password": "fake-password"})
        self.assertEqual((code, payload), (200, {}))
        self.assertEqual(len(transports), 1)
        host, url, authorization, data = transports[0]
        self.assertEqual(host, "127.0.0.1:57321")
        self.assertEqual(url, "http://127.0.0.1:57321/auth/v1/token")
        self.assertEqual(authorization, "Bearer fake-jwt")
        self.assertEqual(json.loads(data), {"password": "fake-password"})

    def test_missing_ownership_acknowledgment_stops_before_external_tools(self):
        services = LocalServices("create_lost")
        error = services.run(acknowledged=False)
        self.assertIn("acknowledgment", str(error))
        self.assertEqual(services.actions, [])

    def test_shared_project_stops_before_external_tools(self):
        services = LocalServices("create_lost")
        error = services.run(project="database-engine")
        self.assertIn("ownership", str(error))
        self.assertEqual(services.actions, [])

    def test_lost_create_response_recovers_only_its_exact_run_email(self):
        services = LocalServices("create_lost")
        services.run()
        self.assertEqual(services.discovery_scopes, [set(services.created_emails)])
        self.assertEqual(len(services.deletions()), 1)
        self.assertEqual(services.registry, {services.foreign_email: services.foreign_id})
        self.assertIn("PASS cleanup receipt", services.output.getvalue())

    def test_unparseable_create_id_is_recovered_without_foreign_user_deletion(self):
        services = LocalServices("bad_id")
        services.run()
        self.assertEqual(len(services.deletions()), 1)
        self.assertEqual(services.registry, {services.foreign_email: services.foreign_id})
        self.assertIn("PASS cleanup receipt", services.output.getvalue())

    def test_failed_logout_retains_users_without_admin_delete(self):
        services = LocalServices("logout_failed")
        error = services.run()
        self.assertIn("retained", str(error))
        self.assertEqual(services.deletions(), [])
        self.assertEqual(len(services.active_sessions), 2)
        self.assertEqual(len(services.registry), 3)
        self.assertIn("FAIL cleanup receipt: incomplete", services.output.getvalue())
        self.assertNotIn("PASS cleanup receipt", services.output.getvalue())

    def test_lost_password_grant_with_unknown_token_retains_live_session_user(self):
        services = LocalServices("grant_lost")
        services.run()
        self.assertEqual(services.deletions(), [])
        self.assertEqual(len(services.active_sessions), 1)
        self.assertNotIn("PASS cleanup receipt", services.output.getvalue())

    def test_unknown_recovery_cannot_report_zero_by_looking_only_at_known_ids(self):
        services = LocalServices("recovery_unknown")
        error = services.run()
        self.assertIn("recovery failed", str(error))
        self.assertEqual(services.deletions(), [])
        self.assertEqual(services.residual_scopes, [set(services.created_emails)])
        self.assertEqual(len(services.registry), 2)
        self.assertIn("FAIL cleanup receipt: incomplete", services.output.getvalue())
        self.assertNotIn("PASS cleanup receipt", services.output.getvalue())


if __name__ == "__main__":
    unittest.main()
