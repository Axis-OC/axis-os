--
-- /lib/dbus.lua
-- AxisOS D-Bus — Ring 3 Message Bus Library
--
-- Provides publish/subscribe event notifications without polling.
--
-- Usage:
--  local dbus = require("dbus")
--
--  -- Subscribe to system events
--  dbus.subscribe("system.component.added")
--  dbus.subscribe("myapp.data.ready")
--
--  -- Wait for next message (blocking)
--  local msg = dbus.poll()
--  if msg then
--      print("Channel:", msg.channel)
--      print("Data:",    msg.data)
--  end
--
--  -- Non-blocking peek
--  if dbus.pending() > 0 then
--      local msg = dbus.poll()
--  end
--
--  -- Publish to a channel
--  dbus.publish("myapp.data.ready", { filename = "/tmp/out.dat" })
--
--  -- Unsubscribe
--  dbus.unsubscribe("system.component.added")
--
--  -- List all channels
--  local channels = dbus.listChannels()
--

local oDbus = {}

--- Create a named channel (idempotent).
function oDbus.createChannel(sName)
    return syscall("dbus_create_channel", sName)
end

--- Subscribe the current process to a channel.
-- The channel is auto-created if it does not exist.
function oDbus.subscribe(sChannel)
    return syscall("dbus_subscribe", sChannel)
end

--- Unsubscribe from a channel.
function oDbus.unsubscribe(sChannel)
    return syscall("dbus_unsubscribe", sChannel)
end

--- Publish a message to all subscribers of a channel.
-- @param sChannel  Channel name string.
-- @param tData     Table of data (strings, numbers, booleans only).
-- @return number   Count of subscribers that received the message.
function oDbus.publish(sChannel, tData)
    return syscall("dbus_publish", sChannel, tData)
end

--- Wait for the next message (blocking).
-- @param nTimeoutMs  Optional timeout in milliseconds.  nil = wait forever.
-- @return table      Message: {channel, data, seq, publisher, time} or nil.
function oDbus.poll(nTimeoutMs)
    return syscall("dbus_poll", nTimeoutMs)
end

--- Return the number of unread messages in the inbox.
function oDbus.pending()
    return syscall("dbus_peek") or 0
end

--- List all registered channels with subscriber counts.
-- @return table  Array of {name=string, subscribers=number}.
function oDbus.listChannels()
    return syscall("dbus_list_channels") or {}
end

--- Convenience: subscribe and return an iterator.
-- Usage:
--  for msg in dbus.listen("system.component.added") do
--      print(msg.data.type, msg.data.address)
--  end
function oDbus.listen(sChannel)
    oDbus.subscribe(sChannel)
    return function()
        return oDbus.poll()
    end
end

--- Well-known system channel names.
oDbus.CHANNEL = {
    COMPONENT_ADDED   = "system.component.added",
    COMPONENT_REMOVED = "system.component.removed",
    MEMORY_LOW        = "system.memory.low",
    PROCESS_SPAWNED   = "system.process.spawned",
    PROCESS_EXITED    = "system.process.exited",
    NETWORK_ONLINE    = "system.network.online",
    NETWORK_OFFLINE   = "system.network.offline",
    DRIVER_LOADED     = "system.driver.loaded",
    DRIVER_QUARANTINED = "system.driver.quarantined",
}

return oDbus