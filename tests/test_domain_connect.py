#!/usr/bin/env python3
"""Tests for the custom-domain / Cloudflare connect feature.

Stdlib only, like the app itself:  python3 -m unittest discover -s tests -v
"""
import json
import os
import sqlite3
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

_tmpdir = tempfile.mkdtemp(prefix="cloak-url-tests-")
os.environ["DB_PATH"] = os.path.join(_tmpdir, "test.db")
os.environ["BASE_URL"] = "https://links.example.com"
os.environ["DOMAIN_CHECK_COOLDOWN"] = "0"

import app  # noqa: E402


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None   # make 302s surface as HTTPError so tests never hit the network


class Base(unittest.TestCase):
    def setUp(self):
        app.DB_PATH = os.environ["DB_PATH"]
        app.init_db()
        conn = sqlite3.connect(app.DB_PATH)
        conn.executescript("DELETE FROM urls; DELETE FROM domains; DELETE FROM meta;")
        conn.commit()
        conn.close()
        app._check_cooldown.clear()
        self._resolve = app.resolve_ips
        self._probe = app.http_probe

    def tearDown(self):
        app.resolve_ips = self._resolve
        app.http_probe = self._probe

    def stub(self, ips, probe=None):
        app.resolve_ips = lambda host, port=443: (ips, None if ips else "DNS lookup failed: NXDOMAIN")
        app.http_probe = lambda url, timeout=None: probe or {
            "status": None, "body": "", "final_url": url, "error": "stub: not called"}


class TestHelpers(Base):
    def test_normalize_domain(self):
        for raw, want in [
            ("https://Links.Example.com/foo", "links.example.com"),
            ("http://example.com:8443/", "example.com"),
            ("  mybrand.com. ", "mybrand.com"),
            ("", ""),
        ]:
            self.assertEqual(app.normalize_domain(raw), want)

    def test_base_domain_from_url_not_scheme(self):
        # regression: split(":")[0] used to return "https" for BASE_URL
        self.assertEqual(app.get_domain_from_host("https://links.example.com"), "links.example.com")
        self.assertEqual(app.get_domain_from_host("example.com:3000"), "example.com")
        self.assertEqual(app.get_domain_from_host("[::1]:3000"), "::1")

    def test_zone_guessing(self):
        self.assertEqual(app.zone_from_domain("links.example.com"), "example.com")
        self.assertEqual(app.zone_from_domain("a.b.example.co.uk"), "example.co.uk")
        self.assertEqual(app.zone_from_domain("example.com"), "example.com")

    def test_cloudflare_links(self):
        links = app.cloudflare_links("links.example.com", "example.com")
        self.assertTrue(links["tunnel_create"].startswith("https://one.dash.cloudflare.com"))
        self.assertEqual(links["zone_dns"], "https://dash.cloudflare.com/?to=/:account/example.com/dns")
        for key in ("tunnel_list", "tunnel_routes", "add_site", "docs_tunnel", "docs_1033", "status"):
            self.assertTrue(links[key].startswith("https://"), key)
        self.assertFalse(links["account_tag_configured"])

    def test_account_tag_deep_links(self):
        old, app.CF_ACCOUNT_TAG = app.CF_ACCOUNT_TAG, "abcd1234"
        try:
            links = app.cloudflare_links("links.example.com", "example.com")
            self.assertEqual(links["tunnel_create"],
                             "https://one.dash.cloudflare.com/abcd1234/networks/tunnels/create/launcher")
            self.assertTrue(links["account_tag_configured"])
        finally:
            app.CF_ACCOUNT_TAG = old

    def test_ip_classification(self):
        self.assertTrue(app.ip_is_cloudflare("104.16.0.5"))
        self.assertTrue(app.ip_is_cloudflare("2606:4700::1"))
        self.assertFalse(app.ip_is_cloudflare("8.8.8.8"))
        for bad in ("127.0.0.1", "10.1.2.3", "169.254.1.1", "192.168.0.1", "::1"):
            self.assertTrue(app.ip_is_private(bad), bad)
        self.assertFalse(app.ip_is_private("93.184.216.34"))

    def test_snippets(self):
        snips = app.tunnel_snippets("links.example.com")
        self.assertEqual(snips["hostname"], "links.example.com")
        self.assertEqual(snips["service"], "http://cloak:3000")
        self.assertIn("cloudflared", snips["compose"])
        self.assertEqual(len(snips["steps"]), 4)


class TestStates(Base):
    def test_live(self):
        body = json.dumps({"app": "cloak-url", "instance_id": app.get_instance_id()})
        self.stub(["104.16.0.1"], {"status": 200, "body": body, "final_url": "", "error": None})
        result = app.classify_domain_check("links.example.com")
        self.assertEqual(result["state"], "live")
        self.assertTrue(result["ok"])
        self.assertTrue(result["dns"]["cloudflare"])

    def test_live_other_instance(self):
        body = json.dumps({"app": "cloak-url", "instance_id": "deadbeef"})
        self.stub(["104.16.0.1"], {"status": 200, "body": body, "final_url": "", "error": None})
        result = app.classify_domain_check("links.example.com")
        self.assertTrue(result["ok"])          # still reachable over the tunnel
        self.assertFalse(result["instance_match"])

    def test_connector_down(self):
        self.stub(["104.16.0.1"], {"status": 530, "body": "Error 1033 Cloudflare Tunnel error",
                                   "final_url": "", "error": None})
        result = app.classify_domain_check("links.example.com")
        self.assertEqual(result["state"], "tunnel_down")
        self.assertEqual(result["http"]["cf_error"], "1033")
        self.assertIn("connector", result["http"]["cf_hint"].lower())

    def test_no_route(self):
        self.stub(["104.16.0.1"], {"status": 404, "body": "Error 1016 Origin DNS error",
                                   "final_url": "", "error": None})
        self.assertEqual(app.classify_domain_check("links.example.com")["state"], "no_route")

    def test_foreign_origin(self):
        self.stub(["93.184.216.34"], {"status": 200, "body": "<html>nginx</html>", "final_url": "", "error": None})
        self.assertEqual(app.classify_domain_check("links.example.com")["state"], "foreign_origin")

    def test_dns_missing(self):
        self.stub([])
        result = app.classify_domain_check("gone.example.com")
        self.assertEqual(result["state"], "dns_missing")
        self.assertIn("does not resolve", result["next_step"])

    def test_private_addresses_are_not_probed(self):
        self.stub(["127.0.0.1", "10.0.0.7"])
        calls = []
        app.http_probe = lambda url, timeout=None: calls.append(url) or {
            "status": 200, "body": "{}", "final_url": "", "error": None}
        result = app.classify_domain_check("internal.example.com")
        self.assertEqual(result["state"], "blocked")
        self.assertEqual(calls, [])   # SSRF guard: no outbound request at all

    def test_tls_error_variants(self):
        self.stub(["104.16.0.1"], {"status": None, "body": "", "final_url": "",
                                   "error": "TLS verify failed: hostname mismatch"})
        out = app.classify_domain_check("deep.links.example.com")
        self.assertEqual(out["state"], "tls_error")
        self.assertIn("Advanced Certificate", out["next_step"])
        self.stub(["104.16.0.1"], {"status": None, "body": "", "final_url": "",
                                   "error": "TLS error: handshake EOF"})
        self.assertIn("handshake", app.classify_domain_check("deep.links.example.com")["next_step"])

    def test_verify_does_not_flood_the_table(self):
        self.stub([])
        app.save_domain("kept.example.com")
        old, app.MAX_DOMAINS = app.MAX_DOMAINS, 1
        try:
            result = app.check_domain_with_cooldown("flood.example.com")
            self.assertEqual(result["state"], "dns_missing")
            self.assertIsNone(app.get_domain_row("flood.example.com"))   # capped, not stored
            self.assertIsNotNone(app.get_domain_row("kept.example.com"))  # existing rows still update
        finally:
            app.MAX_DOMAINS = old

    def test_cooldown(self):
        self.stub(["104.16.0.1"], {"status": 200, "body": json.dumps({"app": "cloak-url"}),
                                   "final_url": "", "error": None})
        app.DOMAIN_CHECK_COOLDOWN = 30
        try:
            app.check_domain_with_cooldown("links.example.com")
            second = app.check_domain_with_cooldown("links.example.com")
            self.assertTrue(second["throttled"])
            self.assertGreater(second["retry_in"], 0)
        finally:
            app.DOMAIN_CHECK_COOLDOWN = 0


class TestDomainStore(Base):
    def test_crud_and_primary(self):
        row = app.save_domain("links.example.com", None, "brand", True)
        self.assertEqual(row["zone"], "example.com")
        self.assertEqual(row["service"], "http://cloak:3000")   # falls back to the configured default
        app.save_domain("go.example.com", "http://cloak:3000", None, False)
        self.assertEqual(app.primary_domain(), "links.example.com")
        app.set_primary_domain("go.example.com")
        self.assertEqual(app.primary_domain(), "go.example.com")
        listed = {d["domain"]: d for d in app.list_domains()}
        self.assertIn("links.example.com", listed)
        self.assertFalse(listed["links.example.com"]["is_primary"])
        # BASE_URL's hostname is flagged so the UI can mark it as "this install"
        self.assertTrue(listed["links.example.com"]["is_base_url"])
        self.assertFalse(listed["go.example.com"]["is_base_url"])
        self.assertEqual(app.delete_domain("links.example.com"), 1)
        self.assertEqual(app.delete_domain("links.example.com"), 0)

    def test_advice_only_for_unverified(self):
        advice = app.domain_advice("brand-new.example.com")
        self.assertFalse(advice["verified"])
        self.assertIn("tunnel_create", advice["links"])
        self.assertIsNone(app.domain_advice("localhost"))
        self.assertIsNone(app.domain_advice(""))


class TestHttpApi(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app.DB_PATH = os.environ["DB_PATH"]
        app.init_db()
        cls.server = HTTPServer(("127.0.0.1", 0), app.Handler)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=10) as r:
            return r.status, json.loads(r.read())

    def redirect(self, code, host=None):
        """GET /code without following redirects; returns (status, location)."""
        headers = {"Host": host} if host else {}
        opener = urllib.request.build_opener(NoRedirect())
        try:
            with opener.open(urllib.request.Request(f"{self.base}/{code}", headers=headers), timeout=10) as r:
                return r.status, r.headers.get("Location")
        except urllib.error.HTTPError as e:
            return e.code, e.headers.get("Location")

    def post(self, path, payload):
        req = urllib.request.Request(self.base + path, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_health_advertises_app_marker(self):
        status, data = self.get("/api/health")
        self.assertEqual(status, 200)
        self.assertEqual(data["app"], "cloak-url")
        self.assertEqual(data["base_domain"], "links.example.com")

    def test_setup_endpoint_with_query_string(self):
        status, data = self.get("/api/cloudflare/setup?domain=https%3A%2F%2FLinks.Example.com%2Fx")
        self.assertEqual(status, 200)
        self.assertEqual(data["domain"], "links.example.com")
        self.assertEqual(data["tunnel"]["steps"][1]["title"], "Add the hostname links.example.com")

    def test_setup_rejects_garbage(self):
        try:
            self.get("/api/cloudflare/setup?domain=not%20a%20domain")
            self.fail("expected 400")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 400)

    def test_save_verify_list_delete(self):
        app.resolve_ips = lambda host, port=443: ([], "NXDOMAIN")
        status, data = self.post("/api/domains", {"domain": "go.example.com", "note": "n"})
        self.assertEqual(status, 200)
        self.assertEqual(data["domain"]["note"], "n")
        status, check = self.post("/api/domains/verify", {"domain": "go.example.com"})
        self.assertEqual(check["state"], "dns_missing")
        status, listing = self.get("/api/domains")
        self.assertEqual(listing["domains"][0]["last_state"], "dns_missing")
        status, gone = self.post("/api/domains/delete", {"domain": "go.example.com"})
        self.assertEqual(gone["deleted"], 1)

    def test_rejects_private_and_bad_input(self):
        self.assertEqual(self.post("/api/domains", {"domain": ""})[0], 400)
        self.assertEqual(self.post("/api/domains", {"domain": "no dots here"})[0], 400)
        self.assertEqual(self.post("/api/domains", {"domain": "a.example.com", "service": "file:///etc"})[0], 400)
        self.assertEqual(self.post("/api/domains/primary", {"domain": "ghost.example.com"})[0], 404)

    def test_shorten_returns_domain_advice(self):
        status, data = self.post("/api/shorten", {"url": "https://example.org/x", "domain": "unverified.example.com"})
        self.assertEqual(status, 200)
        advice = data["domain_advice"]
        self.assertFalse(advice["verified"])
        self.assertTrue(advice["links"]["tunnel_create"].startswith("https://one.dash.cloudflare.com"))
        self.assertEqual(advice["service"], "http://cloak:3000")
        # the link is bound to that hostname, so it only resolves when asked for
        # through it (same as traffic arriving over the tunnel) — no network needed:
        # redirects are not followed.
        code = data["code"]
        opener = urllib.request.build_opener(NoRedirect())
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            opener.open(urllib.request.Request(
                f"{self.base}/{code}", headers={"Host": "unverified.example.com"}), timeout=10)
        self.assertEqual(ctx.exception.code, 302)
        self.assertEqual(ctx.exception.headers.get("Location"), "https://example.org/x")
    def test_lookup_priority_between_base_domain_and_global_bucket(self):
        """A link explicitly bound to BASE_URL's domain must resolve when requested
        through that domain, and the NULL-domain "global" bucket stays the fallback."""
        code = "prio" + str(abs(hash(self.id())) % 1000)
        base = "links.example.com"                      # == BASE_URL host in this suite
        # same code on the base domain and in the global bucket → base domain wins
        self.post("/api/shorten", {"url": "https://target.test/on-base", "domain": base, "custom_code": code})
        self.post("/api/shorten", {"url": "https://target.test/global", "custom_code": code})
        status, loc = self.redirect(code, host=base)
        self.assertEqual(status, 302)
        self.assertEqual(loc, "https://target.test/on-base")
        # another host falls through to the global bucket
        status, loc = self.redirect(code, host="elsewhere.test")
        self.assertEqual(status, 302)
        self.assertEqual(loc, "https://target.test/global")
        # ... and a code bound to a domain is not served on an unrelated host
        other = "bound" + str(abs(hash(self.id())) % 1000)
        self.post("/api/shorten", {"url": "https://target.test/x", "domain": "only.example.net", "custom_code": other})
        self.assertEqual(self.redirect(other, host="elsewhere.test")[0], 404)
        self.assertEqual(self.redirect(other, host="only.example.net")[0], 302)


    def test_list_matches_what_the_host_can_serve(self):
        """Global (NULL-domain) links resolve on any host, so they must also be listed
        there; links bound to a *different* domain must not leak into that list."""
        tag = str(abs(hash(self.id())) % 100000)
        glob = self.post("/api/shorten", {"url": "https://target.test/g" + tag, "custom_code": "g" + tag})[1]
        bound = self.post("/api/shorten", {"url": "https://target.test/b" + tag, "domain": "other.example.net",
                                           "custom_code": "b" + tag})[1]
        status, listing = self.get("/api/urls")
        codes = {u["code"] for u in listing}
        self.assertIn(glob["code"], codes)          # listed: it does resolve on this host
        self.assertNotIn(bound["code"], codes)       # not listed: 404s here
        self.assertEqual(self.redirect(glob["code"], host="unrelated.test")[0], 302)
        self.assertEqual(self.redirect(bound["code"], host="unrelated.test")[0], 404)

    def test_existing_behavior_unchanged(self):
        status, data = self.post("/api/shorten", {"url": "https://example.org/plain", "path_prefix": "blog"})
        self.assertEqual(status, 200)
        self.assertTrue(data["short_url"].endswith("/blog/" + data["code"]))
        self.assertTrue(data["short_url"].startswith("https://links.example.com"))
        # BASE_URL's own domain is trusted, so no "connect it" nag
        self.assertTrue(data["domain_advice"]["verified"])
        self.assertEqual(data["domain_advice"]["state"], "base_url")


    def test_ui_prefills_default_domain_and_shows_connect_link(self):
        import re
        html = open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                 "index.html"), encoding="utf-8").read()
        # every id the script touches must exist in the markup
        used = set(re.findall(r"getElementById\(['\"]([^'\"]+)['\"]\)", html))
        defined = set(re.findall(r'id="([^"]+)"', html))
        self.assertEqual(sorted(used - defined), [])
        for marker in ("savedDomains", "cfPanel", "domainAdvice", "domainList", "cfError", "cfDomain"):
            self.assertIn(f'id="{marker}"', html)
        # default domain is applied only to an empty field (never clobbers typing)
        guard = "if (primary && !domainInput.value.trim()) domainInput.value = primary;"
        self.assertIn(guard, re.sub(r"\s+", " ", html))
        self.assertIn("Connect on Cloudflare →", html)
        self.assertIn("/api/cloudflare/setup", html)

if __name__ == "__main__":
    unittest.main(verbosity=2)
