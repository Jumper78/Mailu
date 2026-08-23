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
      return dovecot.auth.PASSDB_RESULT_OK, {
        proxy = "y",
        host = server,
        port = port,
        nopassword = "Y",
        proxy_noauth = "Y",
      }
    else
      return dovecot.auth.PASSDB_RESULT_PASSWORD_MISMATCH, ""
    end
  else
    return dovecot.auth.PASSDB_RESULT_INTERNAL_FAILURE, ""
  end
end
