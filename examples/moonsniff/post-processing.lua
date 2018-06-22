--- Demonstrates the basic usage of moonsniff in order to determine device induced latencies

local lm        = require "libmoon"
local device    = require "device"
local memory    = require "memory"
local ts        = require "timestamping"
local hist      = require "histogram"
local timer     = require "timer"
local log       = require "log"
local stats     = require "stats"
local barrier   = require "barrier"
local ms	= require "moonsniff-io"
local bit	= require "bit"
local dpdk	= require "dpdk"
local pcap	= require "pcap"
local hmap	= require "hmap"

local ffi    = require "ffi"
local C = ffi.C

-- default values when no cli options are specified
local INPUT_PATH = "latencies.csv"
local INPUT_MODE = C.ms_text
local BITMASK = 0x0FFFFFFF
local TIME_THRESH = -50 	-- negative timevalues smaller than this value are not allowed

local MODE_MSCAP, MODE_PCAP = 0, 1
local MODE = MODE_MSCAP

-- pointers and ctypes
local CHAR_P = ffi.typeof("char *")
local INT64_T = ffi.typeof("int64_t")
local UINT8_T = ffi.typeof("uint8_t")
local UINT8_P = ffi.typeof("uint8_t*")

local free = C.rte_pktmbuf_free_export
local band = bit.band

local pktmatch = nil
local scratchpad = nil
local SCR_SIZE = 16 -- size of the scratchpad in bytes, must always be multiple of 8 for hash to work
local mempool = nil
local mempool2 = nil
local next_mem = 0
local SIP_KEY = ffi.new("uint64_t[2]", {1, 2})

-- skip the initialization of DPDK, as it is not needed for this script
dpdk.skipInit()

function configure(parser)
        parser:description("Demonstrate and test hardware latency induced by a device under test.\nThe ideal test setup is to use 2 taps, one should be connected to the ingress cable, the other one to the egress one.\n\n For more detailed information on possible setups and usage of this script have a look at moonsniff.md.")
	parser:option("-i --input", "Path to input file."):args(1)
	parser:option("-s --second-input", "Path to second input file."):args(1):target("second")
	parser:option("-o --output", "Name of the histogram which is generated"):args(1):default("hist")
	parser:option("-n --nrbuckets", "Size of a bucket for the resulting histogram"):args(1):convert(tonumber):default(1)
	parser:flag("-b --binary", "Read a file which was generated by moonsniff with the binary flag set")
	parser:flag("-d --debug", "Create additional debug information")
        return parser:parse()
end

ffi.cdef[[
	void* malloc(size_t);
	void free(void*);

	uint32_t ms_hash(void*);
	uint32_t ms_get_identifier(void*);

	uint64_t SipHashC(const uint64_t* key, const char* bytes, const uint64_t size);

	// deque definitions
	struct deque_entry{
                uint8_t key[16];
                uint8_t timestamp[8];
        };

        void *deque_create();
        struct deque_entry deque_peek_back(void *queue);
        void deque_remove_back(void *queue);
        void deque_push_front(void *queue, struct deque_entry entry);
	bool deque_empty(void *queue);
]]

function master(args)
	if args.input then INPUT_PATH = args.input end
	if args.binary then INPUT_MODE = C.ms_binary end

	if string.match(args.input, ".*%.pcap") then
		MODE = MODE_PCAP
	--	matchPCAP(args)

	elseif string.match(args.input, ".*%.mscap") then
		MODE = MODE_MSCAP
	end

	print(MODE)
	local PRE
	local POST

	if MODE == MODE_MSCAP then
		if not args.second then log:fatal("Detected .mscap file but there was no second file. Single .mscap files cannot be processed.") end

		if string.match(args.input, ".*%-pre%.mscap") and string.match(args.second, ".*%-post%.mscap") then
			PRE = args.input
			POST = args.second

		elseif string.match(args.second, ".*%-pre%.mscap") and string.match(args.input, ".*%-post%.mscap") then
			POST = args.input
			PRE = args.second
		else
			log:fatal("Could not decide which file is pre and which post. Pre should end with -pre.mscap and post with -post.mscap.")
		end
	end

	if MODE == MODE_PCAP then

		if not args.second then log:fatal("Detected .pcap file but there was no second file. Single .pcap files cannot be processed.") end

		if string.match(args.input, ".*%-pre%.pcap") and string.match(args.second, ".*%-post%.pcap") then
			PRE = args.input
			POST = args.second

		elseif string.match(args.second, ".*%-pre%.pcap") and string.match(args.input, ".*%-post%.pcap") then
			POST = args.input
			PRE = args.second
		else
			log:fatal("Could not decide which file is pre and which post. Pre should end with -pre.mscap and post with -post.mscap.")
		end
	end

	if MODE == MODE_PCAP or MODE == MODE_MSCAP then

		print(PRE)
		print(POST)
		if args.debug then
			log:info("Debug mode")
			if MODE == MODE_MSCAP then
				writeMSCAPasText(PRE, "pre-ts.csv", 1000)
				writeMSCAPasText(POST, "post-ts.csv", 1000)
			else
				writePCAPasText(PRE, "pre-ts.csv", 1000000)
				writePCAPasText(POST, "post-ts.csv", 1000000)
			end
			return
		end

		-- use new tbb matching mode
		if MODE == MODE_PCAP then
			log:info("Using TBB")
			tbbCore(args, PRE, POST)
			return
		end

		local uint64_t = ffi.typeof("uint64_t")
		local uint64_p = ffi.typeof("uint64_t*")

		-- increase the size of map by one to make BITMASK a valid identifier
		local map = C.malloc(ffi.sizeof(uint64_t) * (BITMASK + 1))
		map = ffi.cast(uint64_p, map)

		-- make sure the complete map is zero initialized
		zeroInit(map)

		-- initialize pcap stuff if needed
		setUp()

		C.hs_initialize(args.nrbuckets)

		local prereader = nil
		local postreader = nil

		if MODE == MODE_MSCAP then
			prereader = ms:newReader(PRE)
			postreader = ms:newReader(POST)
		else
			prereader = pcap:newReader(PRE)
			postreader = pcap:newReader(POST)
		end

		-- TODO: check if there are problems with the shared mempool
		local precap = readSingle(prereader)
		local postcap = readSingle(postreader)
		log:info("Pre identifier: " .. tostring(getId(precap)) .. ", Post identifier: " .. tostring(getId(postcap)))

		-- debug and information values
		local overwrites = 0
		local misses = 0
		local pre_count = 0
		local post_count = 0

		log:info("Prefilling Map")

		if precap == nil or postcap == nil then
			log:err("Detected either no pre or post timestamps. Aborting ..")
		end

		pre_count, overwrites = initialFill(precap, prereader, map)

		log:info("Map is now hot")

		while precap and postcap do
			pre_count = pre_count + 1
			post_count = post_count + 1

			local ident = band(getId(precap), BITMASK)

			if map[ident] ~= 0 then
				overwrites = overwrites + 1
			end

			map[ident] = getTs(precap)

			sfree(precap)
			precap = readSingle(prereader)

			post_ident = band(getId(postcap), BITMASK)

			local ts = map[post_ident]

			local diff = ffi.cast(INT64_T, getTs(postcap) - ts)

			-- check for time measurements which violate the given threshold
			if ts ~= 0 and diff < TIME_THRESH then
				log:warn("Got negative timestamp")
				log:warn("Identification " .. ident)
				log:warn("Postcount: " .. post_count)
				log:warn("Pre: " .. tostring(ts) .. "; post: " .. tostring(getTs(postcap)))
				log:warn("Difference: " .. tostring(diff))
				return

			else
				if ts ~= 0 then
					C.hs_update(diff)

					-- reset the ts field to avoid matching it again
					map[ident] = 0
				else
					misses = misses + 1
				end
				sfree(postcap)
				postcap = readSingle(postreader)
			end
		end

		while postcap do
			post_count = post_count + 1

			local ident = band(getId(postcap), BITMASK)
			local ts = map[ident]

			local diff = ffi.cast(INT64_T, getTs(postcap) - ts)

			if ts ~= 0 and diff < TIME_THRESH then
				log:warn("Got negative timestamp")
				log:warn("Identification " .. ident)
				log:warn("Postcount: " .. post_count)
				log:warn("Pre: " .. tostring(ts) .. "; post: " .. tostring(getTs(postcap)))
				log:warn("Difference: " .. tostring(diff))
				return

			elseif ts ~= 0 then

				C.hs_update(diff)

				-- reset the ts field to avoid matching it again
				map[ident] = 0
			else
				misses = misses + 1
			end
			sfree(postcap)
			postcap = readSingle(postreader)
		end

		log:info("Finished timestamp matching")

		prereader:close()
		postreader:close()
		C.free(map)

		tearDown()

		C.hs_finalize()


		print()
		log:info("# pkts pre: " .. pre_count .. ", # pkts post " .. post_count)
		log:info("Packet loss: " .. (1 - (post_count/pre_count)) * 100 .. " %%")
		log:info("")
		log:info("# of identifications possible: " .. BITMASK)
		log:info("Overwrites: " .. overwrites .. " from " .. pre_count)
		log:info("\tPercentage: " .. (overwrites/pre_count) * 100 .. " %%")
		log:info("")
		log:info("Misses: " .. misses .. " from " .. post_count)
		log:info("\tPercentage: " .. (misses/post_count) * 100 .. " %%")
		log:info("")
		log:info("Mean: " .. C.hs_getMean() .. ", Variance: " .. C.hs_getVariance() .. "\n")

		log:info("Finished processing. Writing histogram ...")
		C.hs_write(args.output .. ".csv")
		C.hs_destroy()

	else
        	printStats()
	end
end

function zeroInit(map)
	for i = 0, BITMASK do
		map[i] = 0
	end
end

function initialFill(precap, prereader, map)
        pre_ident = band(getId(precap), BITMASK)
        initial_id = pre_ident

	local overwrites = 0

        local pre_count = 0

        log:info("end : " .. BITMASK - 100)

        while precap and pre_ident >= initial_id and pre_ident < BITMASK - 100 do
                pre_count = pre_count + 1

                if map[pre_ident] ~= 0 then overwrites = overwrites + 1 end
                map[pre_ident] = getTs(precap)

		-- save free in case of pcaps
		sfree(precap)
                precap = readSingle(prereader)
                if precap then
                        pre_ident = band(getId(precap), BITMASK)
                end
        end
	return pre_count, overwrites
end

function writeMSCAPasText(infile, outfile, range)
	local reader = ms:newReader(infile)
	mscap = reader:readSingle()

	textf = io.open(outfile, "w")

	for i = 0, range do
		local ident = band(mscap.identification, BITMASK)

		textf:write(tostring(mscap.identification), ", ", tostring(ident), ", ", tostring(mscap.timestamp), "\n")
		mscap = reader:readSingle()

		if mscap == nil then break end
	end

	reader:close()
	io.close(textf)
end


function writePCAPasText(infile, outfile, range)
	setUp()
	local reader = pcap:newReader(infile)
	cap = readSingle(reader)

	textf = io.open(outfile, "w")

	for i = 0, range do
		local ident = band(getId(cap), BITMASK)

		pkt = cap:getUdpPacket()

		textf:write(tostring(pkt.payload.uint32[0]) .. ", " .. tostring(ident), ", ", tostring(getTs(cap)), "\n")
		sfree(cap)
		cap = readSingle(reader)

		if cap == nil then break end
	end

	reader:close()
	io.close(textf)

	tearDown()
end


--- Setup by loading user defined function and initializing the scratchpad
--- Has no effect if in MODE_MSCAP
function setUp()
	if MODE == MODE_PCAP then
		-- in case of pcap files we need DPDK functions
		dpdk.init()

		-- fetch user defined function
		loaded_chunk = assert(loadfile("examples/moonsniff/pkt-matcher.lua"))
		pktmatch = loaded_chunk()

		-- initialize scratchpad
		scratchpad = C.malloc(ffi.sizeof(UINT8_T) * SCR_SIZE)
		scratchpad = ffi.cast(UINT8_P, scratchpad)

		-- setup the mempool
		mempool = memory.createMemPool()
		mempool2 = memory.createMemPool()
	end
end

function tearDown()
	C.free(scratchpad)
end

function initReader(PRE, POST)
	if MODE == MODE_MSCAP then
		return ms:newReader(PRE), ms:newReader(POST)
	else
		return pcap:newReader(PRE), pcap:newReader(POST)
	end
end


--- Abstract different readers from each other
function readSingle(reader)
	if MODE == MODE_PCAP then
		if next_mem == 0 then
			next_mem = 1
			return reader:readSingle(mempool)
		else
			next_mem = 0
			return reader:readSingle(mempool2)
		end
	else
		return reader:readSingle()
	end
end

--- Save free, will free mbufs
function sfree(cap)
	if MODE == MODE_PCAP then
		free(cap)
	end
end

--- Compute an identification of pcap files
--- Has no effect on mscap files
function getId(cap)
	if MODE == MODE_PCAP then
		-- zero fill scratchpad again
		for i = 0, SCR_SIZE do
			scratchpad[i] = 0
		end

		local filled = pktmatch(cap, scratchpad, SCR_SIZE)
	--	print(scratchpad[0] .. ", " .. scratchpad[1] .. ", " .. scratchpad[2] .. ", " .. scratchpad[3])
		-- log:info("Sip hash of the scratchpad")
		local hash64 = C.SipHashC(SIP_KEY, scratchpad, filled)
		-- log:info("hash: " .. tostring(hash64))

		return hash64
	else
		return cap.identification
	end
end

--- Extract timestamp from pcap and mscaps
function getTs(cap)
	if MODE == MODE_PCAP then
		-- get X552 timestamps
		local timestamp = ffi.cast("uint32_t*", ffi.cast("uint8_t*", cap:getData()) + cap:getSize() - 8)
		local low = timestamp[0]
		local high = timestamp[1]
		return high * 10^9 + low
	else
		return cap.timestamp
	end
end

-- Get the payload identification from pcap file
-- Undefined behavior for packets without identification in the payload
function getPayloadId(cap)
	if MODE == MODE_PCAP then
		local pkt = cap:getUdpPacket()
		return pkt.payload.uint32[0]
	else
		return cap.identification
	end
end

function initHashMap()
	-- we need the values everywhere, therefore, global
	tbbmap = hmap.createHashmap(16, 8)
	tbbmap:clear()
	acc = tbbmap.newAccessor()
	deque = C.deque_create();
	local keyBuf = createBytes(16)

	-- 8 byte timestamps
	local tsBuf = createBytes(8)
	tsBuf = ffi.cast(ffi.typeof("uint64_t *"), tsBuf)
	return keyBuf, tsBuf
end

-- Create a non garbage collected zero initialized byte array
function createBytes(length)
	local bytes = C.malloc(ffi.sizeof(UINT8_T) * length)
        bytes = ffi.cast(UINT8_P, bytes)

	ffi.fill(bytes, length)
	return bytes
end

--- Extract data from an pcap file
--- This is done by an external userdefined function pktmatch which selects some
--- values of the pcap file and copies them into the given buffer
--- Additionally hardware timestamps which are located at the end of the pcap file
--- will be extracted into a seperate buffer
--
-- @param cap the pcap file to extract the data from
-- @param keyBuf a buffer into which the data selcetd by the udf is copied
-- @param tsBuf a buffer into which the timestamp is copied
function extractData(cap, keyBuf, tsBuf)
	-- zero fill scratchpad again
	ffi.fill(scratchpad, SCR_SIZE)

	-- TODO: think again what purpose filled should have ...
	local filled = pktmatch(cap, scratchpad, SCR_SIZE)

--	log:info("filled")

--	log:info("created bytes")
	ffi.copy(keyBuf, scratchpad, 16)

--	log:info("Got key")
--	log:info("TS: " .. tostring(getTs(cap)))

	tsBuf[0] = getTs(cap)
--	log:info("TS after copy: " .. tostring(tmp[0]))
--	log:info("finished copying the timestamp")
end


function addKeyVal(cap, keyBuf, tsBuf)
--	log:info("start of addKeyVal")
	extractData(cap, keyBuf, tsBuf)

--	log:info("try adding")

	-- add the data to the hashmap
	tbbmap:access(acc, keyBuf)
	ffi.copy(acc:get(), tsBuf, 8)

	acc:release()

--	log:info("deque")

	-- add data to the deque
	local entry = C.malloc(ffi.sizeof(ffi.typeof("struct deque_entry")))
	local entry = ffi.new("struct deque_entry", {});
	ffi.copy(entry.key, keyBuf, 16)
	ffi.copy(entry.timestamp, tsBuf, 8)
	C.deque_push_front(deque, entry)
end

function getKeyVal(cap, misses, keyBuf, tsBuf, lastHit)
	extractData(cap, keyBuf, tsBuf)

	local found = tbbmap:find(acc, keyBuf)
	if found then
		local pre_ts = acc:get()
		local post_ts = tsBuf

		pre_ts = ffi.cast(ffi.typeof("uint64_t *"), pre_ts)

--		log:info("Pre: " .. tostring(pre_ts[0]) .. " Post: " .. tostring(post_ts[0]))
		local diff = post_ts[0] - pre_ts[0]
		C.hs_update(diff)

		lastHit = post_ts[0]

--		log:info("Diff: " .. tostring(diff))

		-- delete associated data
		tbbmap:erase(acc)

		acc:release()
	else
		misses = misses + 1
	end

	releaseOld(lastHit)
	return misses, lastHit
end

function releaseOld(lastHit)
	while not C.deque_empty(deque) do
		local entry = C.deque_peek_back(deque)
		local key = entry.key
		local ts = ffi.cast(ffi.typeof("uint64_t *"), entry.timestamp)[0]
--		log:info("TS from queue: " .. tonumber(ts))

		-- check if the current timestamp is old enough
		if ts + 10e6 < lastHit then
			local found = tbbmap:find(acc, key)
			if found then
				local map_ts = ffi.cast(ffi.typeof("uint64_t *"), acc:get())[0]
				if map_ts == ts then
					-- found corrsponding value -> erase it
					tbbmap:erase(acc)
				end
			end

			acc:release()

			-- remove from deque
			C.deque_remove_back(deque)
		else
			break
		end
	end
end

function tbbCore(args, PRE, POST)
	-- for compatability with the other matching options
	MODE = MODE_PCAP

	-- initialize scratchpad and mbufs
	setUp()
	C.hs_initialize(args.nrbuckets)
	local keyBuf, tsBuf = initHashMap()
	local lastHit = 0

	log:info("finished init")

	local prereader, postreader = initReader(PRE, POST)
	local precap = readSingle(prereader)
	log:info("initialized reader")

	-- prefilling
	local ctr = 10000
	while precap and ctr > 0 do
		addKeyVal(precap, keyBuf, tsBuf)
--		log:info("added key")
		sfree(precap)
--		log:info("freeing")
		precap = readSingle(prereader)
	end

	log:info("done prefilling")

	local postcap = readSingle(postreader)
	local misses = 0
	-- map is now hot
	while precap and postcap do
		addKeyVal(precap, keyBuf, tsBuf)
		sfree(precap)
		precap = readSingle(prereader)

		-- now try match
		misses, lastHit = getKeyVal(postcap, misses, keyBuf, tsBuf, lastHit)
		sfree(postcap)
		postcap = readSingle(postreader)
	end

	-- process leftovers
	while postcap do
		misses, lastHit = getKeyVal(postcap, misses, keyBuf, tsBuf, lastHit)
		sfree(postcap)
		postcap = readSingle(postreader)
	end


	prereader:close()
	postreader:close()

	-- free scratchpad
	tearDown()

	C.hs_finalize()

	log:info("Mean: " .. C.hs_getMean() .. ", Variance: " .. C.hs_getVariance() .. "\n")

	log:info("Misses: " .. misses)
	C.hs_destroy()
end


function printStats()
        print()


        stats = C.ms_post_process(INPUT_PATH, INPUT_MODE)
        hits = stats.hits
        misses = stats.misses
        cold = stats.cold_misses
        invalidTS = stats.inval_ts
        print("Received: " .. hits + misses)
        print("\tHits: " .. hits)
        print("\tHits with invalid timestamps: " .. invalidTS)
        print("\tMisses: " .. misses)
        print("\tCold Misses: " .. cold)
        print("\tLoss by misses: " .. (misses/(misses + hits)) * 100 .. "%")
        print("\tTotal loss: " .. ((misses + invalidTS)/(misses + hits)) * 100 .. "%")
        print("Average Latency: " .. tostring(tonumber(stats.average_latency)/10^3) .. " us")

end
