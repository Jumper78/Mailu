function script_init()
  return 0
end

function script_deinit()
end

-- 2.3 called these timeout and max_attempts. In 2.4 the table keys are the
-- http_client_* setting names without the prefix: parse_client_settings() in
-- src/lib-lua/dlua-dovecot-http.c prepends "http_client_" and rejects anything
-- that does not resolve. request_timeout needs an explicit unit in 2.4 - a
-- bare number is rejected with "Time interval is missing units" - so the
-- previous 2000 (milliseconds) is written as "2s".
local http_client = dovecot.http.client {
    request_timeout = "2s";
    request_max_attempts = 3;
}

-- on the other end we use urllib.parse.unquote()
function urlEncode(str)
    return str:gsub("[^%w_.-~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

function addHeader(auth_request, name, value)
  auth_request:add_header(name, value or "")
end

function auth_passdb_lookup(req)
  local auth_request = http_client:request {
    url = "http://{{ ADMIN_ADDRESS }}:8080/internal/auth/email";
  }
  addHeader(auth_request, 'Auth-Port', req.local_port)
  local user = urlEncode(req.user)
  auth_request:add_header('Auth-User', user)
  addHeader(auth_request, 'Auth-Pass', req.password and urlEncode(req.password))
  -- 2.3: req.service - 2.4 renamed that entry of the variable expansion table
  -- to protocol (auth_request_lua_index() in src/auth/db-lua.c).
  -- Every header is sent even when its field is unset, because the endpoint
  -- indexes rather than gets them - flask.request.headers["Client-Ip"] raises
  -- a KeyError and answers 400. A field that is not set reads as nil in 2.4
  -- where 2.3 gave an empty string, and add_header() rejects nil outright, so
  -- addHeader() puts the empty string back. An auth-master PASS lookup, which
  -- is what the lmtp proxy does, has no client connection and therefore none
  -- of these fields.
  addHeader(auth_request, 'Auth-Protocol', req.protocol)
  addHeader(auth_request, 'Client-Ip', req.remote_ip and urlEncode(req.remote_ip))
  addHeader(auth_request, 'Client-Port', req.remote_port)
  addHeader(auth_request, 'Auth-SSL', req.secured)
  addHeader(auth_request, 'Auth-Method', req.mechanism)
  local auth_response = auth_request:submit()
  local resp_status = auth_response:status()

  if resp_status == 200
  then
    if auth_response:header('Auth-Status') == 'OK'
    then
      local server = auth_response:header('Auth-Server')
      local port = auth_response:header('Auth-Port')
      -- 2.3 took the extra fields as a "key=value key=value" string. 2.4 wants
      -- a table on success (auth_lua_call_lookup() in src/auth/db-lua.c:
      -- "expected nil or table"). The field names themselves are unchanged,
      -- see auth_proxy_settings_parse() in src/lib-auth-client/auth-proxy.c.
      -- The error paths below still return a string, which is what 2.4
      -- expects whenever the result is not the success code.
      local reply = {
        proxy = "y",
        host = server,
        port = port,
        nopassword = "Y",
        proxy_noauth = "Y",
      }
      -- A password with 8bit characters cannot go into an IMAP quoted string,
      -- so imap_append_string() (src/lib-imap/imap-quote.c) falls back to a
      -- literal - and to the *synchronizing* form "{17}", not "{17+}", even
      -- though the backend advertises LITERAL+. The backend must therefore
      -- answer "L LOGIN user {17}" with a "+ OK" continuation. At that moment
      -- the connection is switching to the multiplex format, because the
      -- front's ID command asked for it with "x-multiplex" "0": the backend
      -- writes "* ID (...)", "* MULTIPLEX 0" and that "+ OK" as one unframed
      -- block, and only the following segments are framed. imap_proxy_parse_line()
      -- installs the multiplex istream the moment it reads "* MULTIPLEX 0",
      -- so it reads the six bytes of "+ OK" as a frame header and loses the
      -- stream. "L OK Logged in" never arrives, and the login dies in
      -- login_proxy_timeout after 30s with
      --   Login timed out in state=id+capability+login/banner
      -- while the backend has long since logged the user in. Confirmed with
      -- tcpdump against dovecot 2.4.5 (alpine 3.23); dovecot 2.4.1 (alpine
      -- 3.22) was not affected, which is why this surfaced as a base image
      -- regression in tests/compose/core/05_connectivity.py.
      --
      -- proxy_mech makes the front use AUTHENTICATE instead of LOGIN. The
      -- backend advertises SASL-IR, so the credentials go inline as base64 -
      -- pure ASCII, no literal, no continuation, nothing that can desync the
      -- multiplex switch. Only imap is affected: pop3 and submission carry the
      -- password as a plain command argument and keep working as they are.
      if req.protocol == "imap" then
        reply.proxy_mech = "PLAIN"
      end
      return dovecot.auth.PASSDB_RESULT_OK, reply
    else
      return dovecot.auth.PASSDB_RESULT_PASSWORD_MISMATCH, ""
    end
  else
    return dovecot.auth.PASSDB_RESULT_INTERNAL_FAILURE, ""
  end
end
