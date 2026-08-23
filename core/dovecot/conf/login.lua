json = require('json')

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

function urlEncode(str)
    return str:gsub("[^%w_.-~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

function setRequestHeadersFromDovecotRequest(auth_request, req)
    auth_request:add_header('Auth-Port', req.local_port)
    local user = urlEncode(req.user)
    auth_request:add_header('Auth-User', user)
    if req.password ~= nil
    then
        local password = urlEncode(req.password)
        auth_request:add_header('Auth-Pass', password)
    end
    -- 2.3: req.service. The lua request fields are the variable expansion
    -- table (auth_request_lua_index() in src/auth/db-lua.c), and 2.4 renamed
    -- that entry to protocol, so req.service is nil there and the header was
    -- silently left out.
    if req.protocol ~= nil
    then
        auth_request:add_header('Auth-Protocol', req.protocol)
    end

    if req.remote_ip ~= nil
    then
        local client_ip = urlEncode(req.remote_ip)
        auth_request:add_header('Client-Ip', client_ip)
    end
    if req.remote_port ~= nil
    then
        auth_request:add_header('Client-Port', req.remote_port)
    end

    if req.secured ~= nil
    then
        auth_request:add_header('Auth-SSL', req.secured)
    end
    if req.mechanism ~= nil
    then
        auth_request:add_header('Auth-Method', req.mechanism)
    end
end

-- 2.3 expected the extra fields as a "key=value key=value" string, which is
-- what formatJsonToKeyValueString() used to build. 2.4 expects a table on
-- success (auth_lua_call_lookup() in src/auth/db-lua.c: "expected nil or
-- table"), and json.decode already returns exactly that, so the whole
-- conversion is gone. A JSON null decodes to nil and therefore drops out of
-- the table, which is what should happen to the admin API's "password": null.

function auth_passdb_lookup(req)
    local auth_request = http_client:request {
        url = "http://{{ ADMIN_ADDRESS }}:8080/internal/dovecot/passdb/" .. urlEncode(req.user);
    }
    setRequestHeadersFromDovecotRequest(auth_request, req)
    local auth_response = auth_request:submit()
    local resp_status = auth_response:status()

    if resp_status == 200
    then
        return dovecot.auth.PASSDB_RESULT_OK, json.decode(auth_response:payload())
    else
        return dovecot.auth.PASSDB_RESULT_USER_UNKNOWN, ""
    end
end

function auth_userdb_lookup(req)
    local auth_request = http_client:request {
        url = "http://{{ ADMIN_ADDRESS }}:8080/internal/dovecot/userdb/" .. urlEncode(req.user);
    }
    setRequestHeadersFromDovecotRequest(auth_request, req)
    local auth_response = auth_request:submit()
    local resp_status = auth_response:status()

    if resp_status == 200
    then
        return dovecot.auth.USERDB_RESULT_OK, json.decode(auth_response:payload())
    else
        return dovecot.auth.USERDB_RESULT_USER_UNKNOWN, ""
    end
end

function auth_userdb_iterate()
    local auth_request = http_client:request {
        url = "http://{{ ADMIN_ADDRESS }}:8080/internal/dovecot/userdb/";
    }
    local auth_response = auth_request:submit()
    local resp_status = auth_response:status()

    if resp_status == 200
    then
        return json.decode(auth_response:payload())
    else
        return {}
    end
end
