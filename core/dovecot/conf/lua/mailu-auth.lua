-- /etc/dovecot/lua/mailu-auth.lua
-- Mailu authentication via HTTP API (replaces Podop)

local json = require("cjson")  -- Alpine package: lua-cjson

local admin_url = nil
local http_client = nil

function script_init(args)
    admin_url = args["admin_url"] or "http://admin:8080"
    
    http_client = dovecot.http.client {
        timeout = 10000,
        max_attempts = 3,
        connect_timeout = 5000,
        debug = false,
        user_agent = "Dovecot-Mailu/2.4"
    }
    
    return 0
end

function script_deinit()
    -- Cleanup if needed
end

-- Password database lookup
-- Mailu uses nopassword authentication - actual password check happens at nginx
function auth_passdb_lookup(req)
    local url = admin_url .. "/internal/dovecot/passdb/" .. req.user
    
    local http_req = http_client:request {
        url = url,
        method = "GET"
    }
    
    local resp = http_req:submit()
    local status = resp:status()
    
    -- Handle internal errors (9xxx codes)
    if status >= 9000 then
        req:log_error("HTTP connection failed: " .. resp:reason())
        return dovecot.auth.PASSDB_RESULT_INTERNAL_FAILURE, resp:reason()
    end
    
    if status == 404 then
        return dovecot.auth.PASSDB_RESULT_USER_UNKNOWN, ""
    end
    
    if status ~= 200 then
        req:log_error("Admin API error: " .. tostring(status))
        return dovecot.auth.PASSDB_RESULT_INTERNAL_FAILURE, ""
    end
    
    local data = json.decode(resp:payload())
    
    -- Return passdb fields matching Mailu's current behavior
    return dovecot.auth.PASSDB_RESULT_OK, {
        nopassword = data.nopassword or "Y",
        allow_real_nets = data.allow_real_nets or ""
    }
end

-- User database lookup
function auth_userdb_lookup(req)
    local url = admin_url .. "/internal/dovecot/userdb/" .. req.user
    
    local http_req = http_client:request {
        url = url,
        method = "GET"
    }
    
    local resp = http_req:submit()
    local status = resp:status()
    
    if status >= 9000 then
        req:log_error("HTTP connection failed: " .. resp:reason())
        return dovecot.auth.USERDB_RESULT_INTERNAL_FAILURE, resp:reason()
    end
    
    if status == 404 then
        return dovecot.auth.USERDB_RESULT_USER_UNKNOWN, ""
    end
    
    if status ~= 200 then
        req:log_error("Admin API error: " .. tostring(status))
        return dovecot.auth.USERDB_RESULT_INTERNAL_FAILURE, ""
    end
    
    local data = json.decode(resp:payload())
    
    -- Return userdb fields - quota_rule format matches Mailu's current API
    return dovecot.auth.USERDB_RESULT_OK, {
        quota_rule = data.quota_rule or "*:bytes=0"
    }
end

-- User iteration for doveadm -A commands
function auth_userdb_iterate()
    local url = admin_url .. "/internal/dovecot/userdb/"
    
    local http_req = http_client:request {
        url = url,
        method = "GET"
    }
    
    local resp = http_req:submit()
    
    if resp:status() == 200 then
        return json.decode(resp:payload())
    end
    
    return {}

end

function report_quota_update(user, bytes_used)
    local url = admin_url .. "/internal/dovecot/quota/storage/" .. user
    
    local http_req = http_client:request {
        url = url,
        method = "POST"
    }
    http_req:add_header("Content-Type", "application/json")
    http_req:set_payload(tostring(bytes_used))
    
    local resp = http_req:submit()
    return resp:status() == 200
end
