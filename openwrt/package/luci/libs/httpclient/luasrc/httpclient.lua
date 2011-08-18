--[[
LuCI - Lua Development Framework

Copyright 2009 Steven Barth <steven@midlink.org>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

$Id$
]]--

require "nixio.util"
local nixio = require "nixio"

local ltn12 = require "luci.ltn12"
local util = require "luci.util"
local table = require "table"
local coroutine = require "coroutine"
local string = require "string"
local os = require "os"
local http = require "luci.http.protocol"
local date = require "luci.http.protocol.date"

local type, pairs, ipairs, tonumber = type, pairs, ipairs, tonumber
local unpack = unpack

module "luci.httpclient"

function chunksource(sock, buffer)
	buffer = buffer or ""
	return function()
		local output
		local _, endp, count = buffer:find("^([0-9a-fA-F]+);?.-\r\n")
		while not count and #buffer <= 1024 do
			local newblock, code = sock:recv(1024 - #buffer)
			if not newblock then
				return nil, code
			end
			buffer = buffer .. newblock  
			_, endp, count = buffer:find("^([0-9a-fA-F]+);?.-\r\n")
		end
		count = tonumber(count, 16)
		if not count then
			return nil, -1, "invalid encoding"
		elseif count == 0 then
			return nil
		elseif count + 2 <= #buffer - endp then
			output = buffer:sub(endp+1, endp+count)
			buffer = buffer:sub(endp+count+3)
			return output
		else
			output = buffer:sub(endp+1, endp+count)
			buffer = ""
			if count - #output > 0 then
				local remain, code = sock:recvall(count-#output)
				if not remain then
					return nil, code
				end
				output = output .. remain
				count, code = sock:recvall(2)
			else
				count, code = sock:recvall(count+2-#buffer+endp)
			end
			if not count then
				return nil, code
			end
			return output
		end
	end
end


function request_to_buffer(uri, options)
	local source, code, msg = request_to_source(uri, options)
	local output = {}
	
	if not source then
		return nil, code, msg
	end
	
	source, code = ltn12.pump.all(source, (ltn12.sink.table(output)))
	
	if not source then
		return nil, code
	end
	
	return table.concat(output)
end

function request_to_source(uri, options)
	local status, response, buffer, sock = request_raw(uri, options)
	if not status then
		return status, response, buffer
	elseif status ~= 200 and status ~= 206 then
		return nil, status, response
	end
	
	if response.headers["Transfer-Encoding"] == "chunked" then
		return chunksource(sock, buffer)
	else
		return ltn12.source.cat(ltn12.source.string(buffer), sock:blocksource())
	end
end

function create_persistent()
	return coroutine.wrap(function(uri, options)
		local function globe_on()
			os.execute("gpioctl clear 5 > /dev/null")
		end

		local function globe_off()
			os.execute("gpioctl set 5 > /dev/null")
		end

		local status, response, buffer, sock

		local function yield(...)
			if options.headers["Connection"] == "close" then
				sock:close()
			end

			coroutine.yield(...)
		end
	
		while true do
			local output = {}

			globe_off()
			status, response, buffer, sock = request_raw(uri, options, sock)

			if not status then
				uri, options = yield(nil, response or "", buffer)

			elseif status ~= 200 and status ~= 206 then
				if status == 204 then
					globe_on()
				end
	
				uri, options = yield(nil, status, response)

			else
				globe_on()

				local content_length = tonumber(response.headers["Content-Length"])
				local bytes_read = 0

				if content_length > 0 then
					local source = ltn12.source.cat(ltn12.source.string(buffer), sock:blocksource())
					local sink = ltn12.sink.table(output)

					while bytes_read < content_length do
						ltn12.pump.step(source, sink)
						bytes_read = bytes_read + output[#output]:len()
					end

					uri, options = yield(table.concat(output), status, response)
				else
					uri, options = yield("", status, response)
				end
			end
		end
	end)
end

--
-- GET HTTP-resource
--
function request_raw(uri, options, sock)
	options = options or {}
	local pr, host, port, path = uri:match("(%w+)://([%w-.]+):?([0-9]*)(.*)")
	if not host then
		return nil, -1, "unable to parse URI"
	end
	
	if pr ~= "http" and pr ~= "https" then
		return nil, -2, "protocol not supported"
	end
	
	port = #port > 0 and port or (pr == "https" and 443 or 80)
	path = #path > 0 and path or "/"
	
	options.depth = options.depth or 10
	local headers = options.headers or {}
	local protocol = options.protocol or "HTTP/1.1"
	headers["User-Agent"] = headers["User-Agent"] or "LuCI httpclient 0.1"
	
	if headers.Connection == nil then
		headers.Connection = "close"
	end

	-- in case of a persistent connection, the sock object will be passed as arg to request_raw
	if not sock then
		local code, msg
		sock, code, msg = nixio.connect(host, port)

		if not sock then
			return nil, code, msg
		end
	end

	sock:setsockopt("socket", "sndtimeo", options.sndtimeo or 15)
	sock:setsockopt("socket", "rcvtimeo", options.rcvtimeo or 15)

	-- if tls_socket, then we're dealing with a persistent tls connection so skip this part	
	if pr == "https" and not sock:is_tls_socket() then
		local tls = options.tls_context or nixio.tls()
		local tls_context_set_verify = options.tls_context_set_verify or "none"

		if tls_context_set_verify == "peer" then
			tls:set_verify("peer")
			tls:set_verify_locations(options.cacert)
		elseif tls_context_set_verify == "none" then
			tls:set_verify("none")
		end

		sock = tls:create(sock)
		local stat, code, err = sock:connect()
		if not stat then
			return stat, code, err
		end
	end

	-- Pre assemble fixes	
	if protocol == "HTTP/1.1" then
		headers.Host = headers.Host or host
	end
	
	if type(options.body) == "table" then
		options.body = http.urlencode_params(options.body)
	end

	if type(options.body) == "string" then
		headers["Content-Length"] = headers["Content-Length"] or #options.body
		headers["Content-Type"] = headers["Content-Type"] or
			"application/x-www-form-urlencoded"
		options.method = options.method or "POST"
	end
	
	if type(options.body) == "function" then
		options.method = options.method or "POST"
	end

	-- Assemble message
	local message = {(options.method or "GET") .. " " .. path .. " " .. protocol}
	
	for k, v in pairs(headers) do
		if type(v) == "string" or type(v) == "number" then
			message[#message+1] = k .. ": " .. v
		elseif type(v) == "table" then
			for i, j in ipairs(v) do
				message[#message+1] = k .. ": " .. j
			end
		end
	end
	
	if options.cookies then
		for _, c in ipairs(options.cookies) do
			local cdo = c.flags.domain
			local cpa = c.flags.path
			if   (cdo == host or cdo == "."..host or host:sub(-#cdo) == cdo) 
			 and (cpa == "/" or cpa .. "/" == path:sub(#cpa+1))
			 and (not c.flags.secure or pr == "https")
			then
				message[#message+1] = "Cookie: " .. c.key .. "=" .. c.value
			end 
		end
	end
	
	message[#message+1] = ""
	message[#message+1] = ""
	
	-- Send request
	sock:sendall(table.concat(message, "\r\n"))
	
	if type(options.body) == "string" then
		sock:sendall(options.body)
	elseif type(options.body) == "function" then
		local res = {options.body(sock)}
		if not res[1] then
			sock:close()
			return unpack(res)
		end
	end
	
	-- Create source and fetch response
	local linesrc = sock:linesource()
	local line, code, err = linesrc()
	
	if not line then
		sock:close()
		return nil, code, err
	end
	
	local protocol, status, msg = line:match("^([%w./]+) ([0-9]+) (.*)")
	
	if not protocol then
		sock:close()
		return nil, -3, "invalid response magic: " .. line
	end
	
	local response = {
		status = line, headers = {}, code = 0, cookies = {}, uri = uri
	}
	
	line = linesrc()
	while line and line ~= "" do
		local key, val = line:match("^([%w-]+)%s?:%s?(.*)")
		if key and key ~= "Status" then
			if type(response[key]) == "string" then
				response.headers[key] = {response.headers[key], val}
			elseif type(response[key]) == "table" then
				response.headers[key][#response.headers[key]+1] = val
			else
				response.headers[key] = val
			end
		end
		line = linesrc()
	end
	
	if not line then
		sock:close()
		return nil, -4, "protocol error"
	end
	
	-- Parse cookies
	if response.headers["Set-Cookie"] then
		local cookies = response.headers["Set-Cookie"]
		for _, c in ipairs(type(cookies) == "table" and cookies or {cookies}) do
			local cobj = cookie_parse(c)
			cobj.flags.path = cobj.flags.path or path:match("(/.*)/?[^/]*")
			if not cobj.flags.domain or cobj.flags.domain == "" then
				cobj.flags.domain = host
				response.cookies[#response.cookies+1] = cobj
			else
				local hprt, cprt = {}, {}
				
				-- Split hostnames and save them in reverse order
				for part in host:gmatch("[^.]*") do
					table.insert(hprt, 1, part)
				end
				for part in cobj.flags.domain:gmatch("[^.]*") do
					table.insert(cprt, 1, part)
				end
				
				local valid = true
				for i, part in ipairs(cprt) do
					-- If parts are different and no wildcard
					if hprt[i] ~= part and #part ~= 0 then
						valid = false
						break
					-- Wildcard on invalid position
					elseif hprt[i] ~= part and #part == 0 then
						if i ~= #cprt or (#hprt ~= i and #hprt+1 ~= i) then
							valid = false
							break
						end
					end
				end
				-- No TLD cookies
				if valid and #cprt > 1 and #cprt[2] > 0 then
					response.cookies[#response.cookies+1] = cobj
				end
			end
		end
	end
	
	-- Follow 
	response.code = tonumber(status)
	if response.code and options.depth > 0 then
		if response.code == 301 or response.code == 302 or response.code == 307
		 and response.headers.Location then
			local nuri = response.headers.Location or response.headers.location
			if not nuri then
				return nil, -5, "invalid reference"
			end
			if not nuri:find("https?://") then
				nuri = pr .. "://" .. host .. ":" .. port .. nuri
			end
			
			options.depth = options.depth - 1
			if options.headers then
				options.headers.Host = nil
			end
			sock:close()
			
			return request_raw(nuri, options)
		end
	end
	
	return response.code, response, linesrc(true), sock
end

function cookie_parse(cookiestr)
	local key, val, flags = cookiestr:match("%s?([^=;]+)=?([^;]*)(.*)")
	if not key then
		return nil
	end

	local cookie = {key = key, value = val, flags = {}}
	for fkey, fval in flags:gmatch(";%s?([^=;]+)=?([^;]*)") do
		fkey = fkey:lower()
		if fkey == "expires" then
			fval = date.to_unix(fval:gsub("%-", " "))
		end
		cookie.flags[fkey] = fval
	end

	return cookie
end

function cookie_create(cookie)
	local cookiedata = {cookie.key .. "=" .. cookie.value}

	for k, v in pairs(cookie.flags) do
		if k == "expires" then
			v = date.to_http(v):gsub(", (%w+) (%w+) (%w+) ", ", %1-%2-%3 ")
		end
		cookiedata[#cookiedata+1] = k .. ((#v > 0) and ("=" .. v) or "")
	end

	return table.concat(cookiedata, "; ")
end
