-- SPDX-License-Identifier: GPL-2.0-only
-- qos-switch LuCI controller

module("luci.controller.qos-switch", package.seeall)

local fs = require "nixio.fs"

function index()
	if not fs.access("/etc/config/qosmode") then
		return
	end

	entry({"admin", "network", "qos_switch"}, cbi("qos-switch"), "QoS 模式", 60).dependent = true
end
