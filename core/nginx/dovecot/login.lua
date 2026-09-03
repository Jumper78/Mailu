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
      -- Authenticate to the backend with AUTHENTICATE rather than LOGIN.
      --
      -- A password with 8bit characters cannot go into an IMAP quoted string,
      -- so imap_append_string() (src/lib-imap/imap-quote.c) falls back to a
      -- literal - and imap_append_literal() only ever writes the synchronizing
      -- form "{17}", never "{17+}", even though the backend advertises
      -- LITERAL+. dovecot then pipelines the octets without waiting for the
      -- "+" continuation, which RFC 3501 4.3 and RFC 9051 4.3/7.6 forbid: "the
      -- client MUST wait to receive a command continuation request ... before
      -- sending the octet data". RFC 7888 would have permitted "{17+}" here,
      -- and then no continuation would exist at all.
      --
      -- That stray continuation is what breaks the login. The front requests
      -- multiplexing in its ID command ("x-multiplex" "0"), so the backend
      -- answers "* MULTIPLEX 0" and switches to the framed format, which opens
      -- with a 9 byte header (FF FF FF FF FF 00 02 03 FE, see
      -- src/lib/iostream-multiplex-private.h). The "+ OK" however is written by
      -- the IMAP parser to the ostream it captured at imap_parser_create()
      -- time, and client_multiplex_output_start() swaps client->output without
      -- re-pointing the parser - only imap_client_starttls() does that. So the
      -- six bytes are emitted in front of the header instead of behind it
      -- (tcpdump shows them in one unframed 46 byte block), the header never
      -- parses, "L OK Logged in" never arrives, and the login dies after
      -- login_proxy_timeout with
      --   Login timed out in state=id+capability+login/banner (after 30 secs)
      -- while the backend has long since logged the user in.
      --
      -- dovecot 2.4.1 (alpine 3.22) survived this by accident: its multiplex
      -- ostream uncorked the parent on every send, so the header reached the
      -- wire before the continuation was written and the stray line landed
      -- inside the channel 0 data, where imap-proxy.c drops it on purpose
      -- ("used literals with LOGIN command, just ignore"). 2.4.5 (alpine 3.23)
      -- took that accident away with f415f9c59, which correctly gave the
      -- multiplex ownership of the parent's cork. Nothing on this path has
      -- changed in dovecot main since, so waiting it out is not an option.
      --
      -- proxy_mech removes the literal instead: AUTHENTICATE carries the
      -- credentials base64-encoded and inline, because the backend advertises
      -- SASL-IR. It is also the better path irrespective of the bug - RFC 9051
      -- 6.2.3 says LOGIN "SHOULD NOT be used except as a last resort" while
      -- 6.1.1 makes AUTH=PLAIN mandatory to implement, and dovecot implements
      -- LOGIN as SASL PLAIN anyway (is_login_cmd_disabled() refuses LOGIN when
      -- PLAIN is unavailable). Confidentiality is unchanged: base64 is not
      -- encryption and this hop is exactly as exposed as it was before.
      --
      -- Only imap needs this. pop3 and submission pass the password as a plain
      -- command argument, never build a literal, and are left alone.
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
