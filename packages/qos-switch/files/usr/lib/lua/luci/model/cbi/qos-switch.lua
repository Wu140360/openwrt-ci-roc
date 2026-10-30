-- SPDX-License-Identifier: GPL-2.0-only
-- qos-switch LuCI CBI model（界面文字直接使用简体中文）

local sys = require "luci.sys"
local util = require "luci.util"
local fs = require "nixio.fs"

local m, s, o

m = Map("qosmode", "QoS 模式切换",
	"三种模式互斥：关闭（满血 NSS 硬件加速）、硬件简易 QoS（NSS 整形，实验）、软件多功能 QoS（qosify + CAKE，需停用 ECM）。")

s = m:section(NamedSection, "main", "qosmode", "模式与带宽")

o = s:option(ListValue, "mode", "当前 QoS 模式")
o:value("off", "关闭（默认，满血 NSS 硬件加速）")
o:value("nss", "硬件简易 QoS（NSS 整形，实验）")
o:value("qosify", "软件多功能 QoS（qosify + CAKE）")
o.default = "off"
o.rmempty = false

o = s:option(Value, "wan", "WAN 逻辑接口")
o.default = "wan"
o.datatype = "uciname"
o.rmempty = false

o = s:option(Value, "src_dev", "NSS 物理接口（nssifb 源设备）")
o.default = "eth0"
o.rmempty = false

o = s:option(Value, "upload", "上行带宽（kbit/s，0 为不限速）")
o.datatype = "uinteger"
o.default = "0"
o.rmempty = false

o = s:option(Value, "download", "下行带宽（kbit/s，0 为不限速）")
o.datatype = "uinteger"
o.default = "0"
o.rmempty = false

-- 保存并应用后立刻切换
m.on_after_commit = function()
	sys.call("/usr/sbin/qos-switch apply >/dev/null 2>&1")
end

local s2 = m:section(SimpleSection, "当前生效状态")

local running = fs.readfile("/var/run/qos-switch.mode")
running = running and running:gsub("%s+$", "") or ""

local cur = s2:option(DummyValue, "_running", "当前运行模式")
cur.value = (running ~= "" and running) or "未应用（默认 off，满血 NSS 硬件加速）"

local status = s2:option(DummyValue, "_tc")
status.rawhtml = true
status.value = "<pre style=\"white-space:pre-wrap\">" ..
	util.pcdata(sys.exec("tc -s qdisc show 2>/dev/null | head -n 60")) ..
	"</pre>"

local apply = s2:option(Button, "_apply", "立即应用（不修改配置）")
apply.inputstyle = "apply"
apply.write = function()
	sys.call("/usr/sbin/qos-switch apply >/dev/null 2>&1")
end

return m
