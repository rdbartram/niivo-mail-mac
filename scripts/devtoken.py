#!/usr/bin/env python3
"""Interactive browser sign-in (auth code + PKCE, loopback redirect) for testing against a real tenant
before the app bundle is signed with keychain entitlements. Device-code flow is commonly blocked by
Conditional Access, so this uses a normal browser sign-in instead.

usage: devtoken.py <tenant_id> <client_id> <out_file> [login_hint]
Opens the browser, waits for the redirect on http://localhost:<port>, writes ONLY the access token to
out_file (mode 0600). Requires "http://localhost" as a public-client redirect URI on the app registration.

MIP mode (for scripts/MIPProbe, docs/MIP.md):
usage: devtoken.py --mip <tenant_id> <client_id> <out_file.json> [login_hint]
One browser PKCE sign-in for Graph mail (Mail.ReadWrite), then the refresh token is redeemed (in memory only,
never written) for Azure Rights Management (https://aadrm.com/user_impersonation) and the MIP Sync Service
(https://syncservice.o365syncservice.com/UnifiedPolicy.User.Read). Writes JSON {upn, graph, rms, sync} with mode
0600. Never device code. Prints only expiry/scopes, never tokens.
"""
import base64, hashlib, http.server, json, os, secrets, subprocess, sys, urllib.parse, urllib.request

argv = sys.argv[1:]
mip = bool(argv) and argv[0] == "--mip"
if mip: argv = argv[1:]
tenant, client, out = argv[0:3]
hint = argv[3] if len(argv) > 3 else None
if mip:
    scopes = "https://graph.microsoft.com/User.Read https://graph.microsoft.com/Mail.ReadWrite offline_access openid profile"
else:
    scopes = "https://graph.microsoft.com/User.Read https://graph.microsoft.com/Calendars.ReadWrite.Shared " \
             "https://graph.microsoft.com/InformationProtectionPolicy.Read offline_access openid profile"
MIP_SCOPES = {"rms": "https://aadrm.com/user_impersonation offline_access",
              "sync": "https://syncservice.o365syncservice.com/UnifiedPolicy.User.Read offline_access"}
base = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0"

verifier = secrets.token_urlsafe(64)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
state = secrets.token_urlsafe(16)
result = {}

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
        if "code" not in q and "error" not in q:
            self.send_response(404); self.end_headers(); return
        result.update(q)
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(b"<h3>Signed in. You can close this tab and go back to the terminal.</h3>")
    def log_message(self, *a): pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
redirect = f"http://localhost:{srv.server_port}"
params = {"client_id": client, "response_type": "code", "redirect_uri": redirect, "scope": scopes,
          "code_challenge": challenge, "code_challenge_method": "S256", "state": state, "prompt": "login"}
if hint: params["login_hint"] = hint
url = f"{base}/authorize?" + urllib.parse.urlencode(params)
print(f"Opening browser for sign-in (redirect {redirect}). If it doesn't open, visit:\n{url}", flush=True)
if not os.environ.get("NO_OPEN"): subprocess.run(["open", url], check=False)

srv.timeout = 600
while not result:
    srv.handle_request()
if result.get("state") != state:
    sys.exit("state mismatch — aborting")
if "error" in result:
    sys.exit(f"sign-in failed: {result['error']}: {result.get('error_description', '')[:300]}")

req = urllib.request.Request(f"{base}/token", data=urllib.parse.urlencode({
    "grant_type": "authorization_code", "client_id": client, "code": result["code"],
    "redirect_uri": redirect, "code_verifier": verifier, "scope": scopes}).encode(),
    )
try:
    with urllib.request.urlopen(req) as r: tok = json.load(r)
except urllib.error.HTTPError as e:
    tok = json.load(e)
if "access_token" not in tok:
    sys.exit(f"token failed: {tok.get('error')}: {tok.get('error_description', '')[:300]}")
check_url = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox?$select=id" if mip else \
            "https://graph.microsoft.com/v1.0/me/calendar?$select=id"
try:  # refuse tokens for accounts without an Exchange mailbox (e.g. a cloud-only admin account)
    urllib.request.urlopen(urllib.request.Request(check_url,
                                                  headers={"Authorization": "Bearer " + tok["access_token"]}))
except urllib.error.HTTPError as e:
    err = (json.load(e).get("error") or {}).get("code")
    claims = tok["access_token"].split(".")[1]; claims += "=" * (-len(claims) % 4)
    upn = json.loads(base64.urlsafe_b64decode(claims)).get("upn")
    sys.exit(f"signed in as {upn}: no usable mailbox ({e.code} {err}) — sign in with the mailbox account")

if mip:
    claims = tok["access_token"].split(".")[1]; claims += "=" * (-len(claims) % 4)
    upn = json.loads(base64.urlsafe_b64decode(claims)).get("upn") or ""
    result_json = {"upn": upn, "graph": tok["access_token"]}
    refresh = tok.get("refresh_token")
    if not refresh:
        sys.exit("no refresh token returned (offline_access) — cannot redeem RMS/sync tokens")
    for key, sc in MIP_SCOPES.items():
        r2 = urllib.request.Request(f"{base}/token", data=urllib.parse.urlencode({
            "grant_type": "refresh_token", "client_id": client, "refresh_token": refresh, "scope": sc}).encode())
        try:
            with urllib.request.urlopen(r2) as r: t2 = json.load(r)
        except urllib.error.HTTPError as e:
            t2 = json.load(e)
        if "access_token" not in t2:
            print(f"{key}: token failed: {t2.get('error')}: {t2.get('error_description', '')[:200]}", flush=True)
            continue
        result_json[key] = t2["access_token"]
        refresh = t2.get("refresh_token", refresh)  # rotate in memory only
        print(f"{key}: token ok ({t2.get('expires_in')}s, scopes: {t2.get('scope')})", flush=True)
    refresh = None
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, json.dumps(result_json).encode()); os.close(fd)
    print(f"tokens written to {out} (graph {tok.get('expires_in')}s; keys: {', '.join(result_json)})", flush=True)
    sys.exit(0)

fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, tok["access_token"].encode()); os.close(fd)
print(f"token written ({tok.get('expires_in')}s, scopes: {tok.get('scope')})", flush=True)
