## 10. I/O Request Packets (IRPs)

### 10.1 Structure

An IRP is a Lua table representing a single I/O operation:

```lua
{
    nMajorFunction = 0x03,          -- IRP_MJ_READ
    pDeviceObject  = nil,           -- set by driver
    tParameters    = {              -- operation-specific data
        sData   = nil,              -- for WRITE: the data to write
        sMethod = nil,              -- for DEVICE_CONTROL: method name
        tArgs   = {},               -- for DEVICE_CONTROL: arguments
    },
    tIoStatus      = {
        nStatus      = 0,           -- STATUS_SUCCESS, etc.
        vInformation = nil,         -- return value (bytes read, etc.)
    },
    nSenderPid     = 5,             -- originating process
    sDeviceName    = "\\Device\\TTY0",
    nFlags         = 0,             -- IRP_FLAG_NO_REPLY = 0x10
}
```

### 10.2 Major Function Codes

| Code | Name | Description |
|------|------|-------------|
| `0x00` | `IRP_MJ_CREATE` | Open device (equivalent to `open()`) |
| `0x02` | `IRP_MJ_CLOSE` | Close device handle |
| `0x03` | `IRP_MJ_READ` | Read data from device |
| `0x04` | `IRP_MJ_WRITE` | Write data to device |
| `0x0E` | `IRP_MJ_DEVICE_CONTROL` | Device-specific control (ioctl) |

### 10.3 IRP Lifecycle

```
  1. PM creates IRP           2. DKMS routes IRP
  ┌─────────────┐            ┌──────────────┐
  │ fNewIrp()   │           │ DispatchIrp() │
  │ Set fields  │──────────►│ Find device   │
  │ Send to DKMS│           │ Find handler  │
  └─────────────┘           │ signal driver │
                             └──────┬───────┘
                                    │
  4. PM wakes caller          3. Driver processes
  ┌──────────────┐           ┌──────────────┐
  │ signal_send  │◄──────────│ Do work      │
  │ to caller    │           │ Fill IoStatus│
  │ with result  │           │ Complete IRP │
  └──────────────┘           └──────────────┘
```

### 10.4 Completing an IRP

Drivers **must** call `DkCompleteRequest` for every IRP they receive:

```lua
local function fMyReadHandler(pDeviceObject, pIrp)
    local sData = "Hello, World!"
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, sData)
end
```

> **Warning:** Failing to complete an IRP will leave the calling process sleeping forever. Always complete IRPs, even on error.

---
