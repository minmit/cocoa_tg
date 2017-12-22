local mg		= require "moongen" 
local device	= require "device"
local memory	= require "memory"
local stats		= require "stats"
local log		= require "log"
local ts		= require "timestamping"
local hist		= require "histogram"
local timer		= require "timer"


local TX_QUEUES = 4
local RX_QUEUES = 1

local ETH_DST = {"52:54:00:4b:9e:17", "52:54:00:9b:ad:dc",
                 "52:54:00:d0:b3:df"} 
--local ETH_DST	= "52:54:00:4b:9e:17" -- VM1
--local ETH_DST   = "52:54:00:9b:ad:dc" -- VM2

local IP_DST	= "192.168.0.2"
local IP_SRC	= "192.168.0.10"
local NUM_FLOWS	= 200 -- src ip will be IP_SRC + random(0, NUM_FLOWS - 1)


local PORT_DST	= 2345
local PORT_SRC	= 1234


local MIN_PKT_SIZE	= 128 -- without CRC
local MAX_PKT_SIZE = 1500



function configure(parser)
	parser:description("Generates traffic to DUT")
	parser:argument("txDev", "Device to transmit from."):convert(tonumber)
	parser:argument("rxDev", "Device to receive from."):convert(tonumber)
	parser:argument("vmID", "VM to send traffic to."):convert(tonumber)
    parser:option("-r --rate", "rate in Mbit/s."):default(10000):convert(tonumber):target("rate")
    parser:option("-s --size", "paket size in bytes, or r, or d"):default("r"):target("pkt_size")
end

function master(args)
	local txDev, rxDev, queue_rate
	
	if args.txDev == args.rxDev then
		-- sending and receiving from the same port
		txDev = device.config{port = args.txDev, rxQueues = RX_QUEUES + 1, txQueues = TX_QUEUES + 1}
		rxDev = txDev
	else
		-- two different ports, different configuration
		txDev = device.config{port = args.txDev, rxQueues = 1, txQueues = TX_QUEUES + 1}
		rxDev = device.config{port = args.rxDev, rxQueues = RX_QUEUES + 1}
	end

	-- wait until the links are up
	device.waitForLinks()
    log:info("Sending %d MBit/s traffic", args.rate)
	

    queue_rate = args.rate / TX_QUEUES
   
    -- setup rate limiters for CBR traffic
	for i = 0,TX_QUEUES - 1 do
        txDev:getTxQueue(i):setRate(queue_rate)
    end

    local random = false
    local distro = false
    local const = MIN_PKT_SIZE

    if args.pkt_size == "r" then
        random = true
    elseif args.pkt_size == "d" then
        distro = true
    elseif tonumber(args.pkt_size) ~= nil then
        const = tonumber(args.pkt_size)
    end
   
    if args.rate > 0 then
        if random then
            for i = 0, TX_QUEUES - 1 do
                mg.startTask('randPktSizeLoadSlave', txDev:getTxQueue(i), i, args.vmID)
            end 
        elseif distro then
        else
            for i = 0, TX_QUEUES - 1 do
                mg.startTask('constPktSizeLoadSlave', txDev:getTxQueue(i), i, const, args.vmID)
            end
        end
	end

    for i = 0, RX_QUEUES - 1 do
	    mg.startTask("counterSlave", rxDev:getRxQueue(i), i)
    end
	-- measure latency from a second queue
	mg.startSharedTask("timerSlave", txDev, txDev:getTxQueue(TX_QUEUES), rxDev:getRxQueue(RX_QUEUES), args.vmID)
	-- wait until all tasks are finished
	
    mg.waitForTasks()
end

function constPktSizeLoadSlave(queue, queue_id, pkt_size, vm_id)

	mg.sleepMillis(100) -- wait a few milliseconds to ensure that the rx thread is running

    
    local mem = memory.createMemPool(function(buf)
        buf:getUdpPacket():fill{
            pktLength = pkt_size,
            ethSrc = queue, -- get the src mac from the device
            ethDst = ETH_DST[vm_id],
            -- ipSrc will be set later as it varies
            ip4Dst = IP_DST,
            -- udpSrc will be set later  as it varies
            udpDst = PORT_DST,
            -- payload will be initialized to 0x00 as new memory pools are initially empty
        }
    end)

	local txCtr = stats:newManualTxCounter("Queue " .. queue_id, "plain")
	local baseIP = parseIPAddress(IP_SRC)

	-- a buf array is essentially a very thin wrapper around a rte_mbuf*[], i.e. an array of pointers to packet buffers
	local bufs = mem:bufArray()
	while mg.running() do
		-- allocate buffers from the mem pool and store them in this array
		bufs:alloc(pkt_size)
		for _, buf in ipairs(bufs) do
			-- modify some fields here
			local pkt = buf:getUdpPacket()
			-- select a randomized source IP address
			-- you can also use a wrapping counter instead of random
			pkt.ip4.src:set(baseIP + math.random(NUM_FLOWS) - 1)
			pkt.udp:setSrcPort(PORT_SRC + math.random(NUM_FLOWS) - 1)
            -- you can modify other fields here (e.g. different source ports or destination addresses)
		end
		-- send packets
		bufs:offloadUdpChecksums()
		txCtr:updateWithSize(queue:send(bufs), pkt_size)
	end
	txCtr:finalize()
end

function randPktSizeLoadSlave(queue, queue_id, vm_id)

	mg.sleepMillis(100) -- wait a few milliseconds to ensure that the rx thread is running

    local mem = memory.createMemPool(function(buf)
        buf:getUdpPacket():fill{
            ethSrc = queue, -- get the src mac from the device
            ethDst = ETH_DST[vm_id],
            -- ipSrc will be set later as it varies
            ip4Dst = IP_DST,
            -- udpSrc will be set later  as it varies
            udpDst = PORT_DST,
            -- payload will be initialized to 0x00 as new memory pools are initially empty
        }
    end)

	local txCtr = stats:newPktTxCounter("Queue " .. queue_id, "plain")
	local baseIP = parseIPAddress(IP_SRC)

	-- a buf array is essentially a very thin wrapper around a rte_mbuf*[], i.e. an array of pointers to packet buffers
	local bufs = mem:bufArray()
	while mg.running() do
		-- allocate buffers from the mem pool and store them in this array
        local pkt_size = math.random(MIN_PKT_SIZE, MAX_PKT_SIZE)
		bufs:alloc(pkt_size)
		for _, buf in ipairs(bufs) do
			-- modify some fields here
			local pkt = buf:getUdpPacket()
            pkt:setLength(pkt_size)
			pkt.ip4.src:set(baseIP + math.random(NUM_FLOWS) - 1)
			pkt.udp:setSrcPort(PORT_SRC + math.random(NUM_FLOWS) - 1)
            txCtr:countPacket(buf)
		end
		-- send packets
		bufs:offloadUdpChecksums()
        queue:send(bufs)
        txCtr:update()
	end
	txCtr:finalize()
end

function counterSlave(queue, queue_id)
	local bufs = memory.bufArray()
    local rxCtr = stats:newPktRxCounter("Queue" .. queue_id, "plain")
	
    while mg.running(100) do
		local rx = queue:recv(bufs)
		for i = 1, rx do
			local buf = bufs[i]
			rxCtr:countPacket(buf)
		end
		-- update() on rxPktCounters must be called to print statistics periodically
		-- this is not done in countPacket() for performance reasons (needs to check timestamps)
		rxCtr:update()
		bufs:freeAll()
	end
    rxCtr:finalize()
end

function timerSlave(txDev, txQueue, rxQueue, vm_id)
	local txDev = txQueue.dev
	local rxDev = rxQueue.dev
	local timestamper = ts:newUdpTimestamper(txQueue, rxQueue)
	local histUdp = hist()
	-- wait one second, otherwise we might start timestamping before the load is applied
	mg.sleepMillis(1000)
	local baseIP = parseIPAddress(IP_SRC)
	local rateLimit = timer:new(0.01)
	while mg.running() do
		local lat = timestamper:measureLatency(MIN_PKT_SIZE, function(buf)
			local pkt = buf:getUdpPacket()
			--[[pkt:fill{
				pktLength = MIN_PKT_SIZE, -- this sets all length headers fields in all used protocols
				ethSrc = txQueue, -- get the src mac from the device
				ethDst = ETH_DST,
				-- ipSrc will be set later as it varies
				ip4Dst = IP_DST,
				udpDst = PORT_DST + 1,
			}--]]
            pkt.eth.src:set(txDev:getMac(true))
            pkt.eth.dst:setString(ETH_DST[vm_id])
			pkt.ip4.src:set(baseIP + math.random(NUM_FLOWS) - 1)
            pkt.ip4.dst:set(parseIPAddress(IP_DST))
            pkt.udp:setSrcPort(PORT_SRC + math.random(NUM_FLOWS) - 1)
		end)
		if lat then
            histUdp:update(lat)
        else
            --log:info("didn't get lat")
		end
		rateLimit:wait()
		rateLimit:reset()
	end
	mg.sleepMillis(100) -- to prevent overlapping stdout
	--histUdp:save("hist-udp.csv")
	histUdp:print("udp traffic")
end

