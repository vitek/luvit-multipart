-- ----------------------------------------------------------------------------
-- "THE BEER-WARE LICENSE" (Revision 42):
-- <xxleite@gmail.com> wrote this file. As long as you retain this notice you
-- can do whatever you want with this stuff. If we meet some day, and you think
-- this stuff is worth it, you can buy me a beer in return
-- ----------------------------------------------------------------------------

-- multipart stream parse

local fs     = require 'fs'
local tb     = require 'table'
local st     = require 'string'
local os     = require 'os'
local co     = require 'coroutine'
local math   = require 'math'
local writer = require './stream'

local exists, create, status, yield, resume, format, match, gsub, sub, lower, insert, concat, each, random, seed, time = 
				fs.exists, co.create, co.status, co.yield, co.resume, st.format, st.match, st.gsub, st.sub, st.lower, tb.insert, tb.concat, tb.foreach, math.random, math.randomseed, os.time

local temp_path, finish_callback, coroutine, stream_handler, errors, headers, header, queue, stream, m_boundary, m_eos, line, last_line, i =
				'', function() end, nil, nil, false, {}, {}, {}, '', '', '', '', '', 0

fs, tb, st, os, co, math = nil, nil, nil, nil, nil, nil

local function detect(table, value)
  local function _each_pairs(k, v)
    if v==value then return true end
  end
  return each(table, _each_pairs)==true
end

-- parse mime/multipart headers
local function get_headers(data)
	local header, headers = match(data, "^"..m_boundary.."\r?\n(.-\r?\n\r?\n)"), {} --"\r?\n?(.-%c)%c"), {}
	p('get_headers', #header)
	local headers_loop    = function(k, v) headers[k] = v end
	if header then
		gsub(header, '%s?([^%:?%=?]+)%:?%s?%=?%"?([^%"?%;?%c?]+)%"?%;?%c?', headers_loop)
		p('header parsed', headers)
		return headers, sub(data, #m_boundary+#header+3)
	end
	return nil, data
end

--
local function unique_file_name(name)
	seed(192837465)
	return format("%s/%d_%d_%s", temp_path, random(19375, 293847560), time(), name)
end

local function write_data_block(err) 
	if err then
		-- cannot write or close file ... permission?, disk failure?, wtf!
		p('ERROR', err)
	end
	--p('will resume ...')
	resume(coroutine)
end

-- finish data blocks
local function finish_data_block()
	p('closing ...', stream_handler.is_free())
	if not stream_handler.is_free() then
		-- close file handler
		stream_handler.close(write_data_block)
		yield()
	end
end

-- parse body/multipart
local function parse(data)

	line = match(data, "(.-\n)")

	if not line or line=='' then
		p('line incompleted')
		finish_callback()
		return false
	end

	if line == m_boundary.."\n" or line == m_boundary.."\r\n" then
		p('boundary reached')
		finish_data_block()
		insert(headers, header)
		header, stream = get_headers(data)
		if not header then
			finish_callback()
			return false
		end
	elseif line == m_eos.."\n" or line == m_eos.."\r\n" then
		p('end boundary')
		finish_data_block()
		insert(headers, header)
		finish_callback()
		stream = ''
		return false
	else
		if header.filename then
			if stream_handler.is_free() then
				stream_handler.new(unique_file_name(header.filename))
			end
			stream_handler.write(line, write_data_block)
			yield()
		else
			header.value = (last_line==m_boundary.."\r\n" or last_line==m_boundary.."\n" or last_line=='') and line or header.value.."\n"..line
		end
		stream = sub(data, #line+1)
	end
	last_line = line
	parse(stream)
end

local function on_stream_arrival(chunk, length) 

	if not coroutine then
		p('on stream arrival -- coroutine absent', coroutine, #queue)
		coroutine = create(parse)
		stream    = chunk
	elseif status(coroutine)=='dead' then
		p('on stream arrival -- coroutine dead', status(coroutine), #queue)
		coroutine = create(parse)
		stream    = stream .. concat(queue) .. chunk
		queue     = {}
	else
		p('on stream arrival -- queue stream', status(coroutine), #queue)
		insert(queue, chunk)
		return
	end

	if m_boundary=='' or not header then
		-- read first bundary 
		m_boundary = m_boundary==''                and match(stream, "^([^\r?\n?]+)\n?\r?") or m_boundary
		m_eos      = (#m_boundary>0 and m_eos=='') and m_boundary..'--'                     or m_eos
		p('boundaries', m_boundary, m_eos)
		if not m_boundary then 
			return
		end
		-- get headers
		header, stream = get_headers(stream)
		if not header then
			return
		end			
		-- initialize stream writer
		stream_handler = writer('')	
	end

	resume(coroutine, stream)
end

-- 
return function (ops)

	ops               = ops            and ops            or {}
	temp_path         = ops.temp_path  and ops.temp_path  or './tmp'
	ops.methods       = ops.methods    and ops.methods    or {'POST'}
	ops.endpoints     = ops.end_points and ops.end_points or {'.'}
	exists(temp_path, function(err, _exists) p(err, _exists) errors = (err~=nil or not _exists) end)
	p('middleware loaded')
  
  -- handler
  return function (req, res, nxt)
  	if not errors then
  		if detect(ops.methods, req.method) then

  			p('middleware in use')

	  		local function on_stream_finish()
	  			p('on stream finish', #queue)
					on_stream_arrival('', 0)
					finish_callback = function()
						if #queue==0 then
							p('next route/middleware')
							nxt()
						else
							stream = stream .. concat(queue)
							p('finish him') --, #stream, sub(stream, 1, 60))
							queue  = {}
							parse(stream)
						end
					end
				end

		  	req:on('data', on_stream_arrival)
		  	req:on('end',  on_stream_finish)
	  	else
	  		p('method not match ... goto next')
	  		nxt()
	  	end
		else
			p('error ocurred ... goto next')
			nxt()
		end
	end
end