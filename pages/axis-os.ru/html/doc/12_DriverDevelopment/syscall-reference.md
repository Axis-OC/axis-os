## 15. Syscall Reference

### 15.1 Process Management

| Syscall | Rings | Parameters | Returns |
|---------|-------|------------|---------|
| `process_spawn` | 0-3 | `sPath, nRing, tEnv` | `nPid` or `nil, sErr` |
| `process_thread` | 0-3 | `fFunc` | `nThreadPid` or `nil, sErr` |
| `process_wait` | 0-3 | `nTargetPid` | `true` when target exits |
| `process_kill` | 0-3 | `nTargetPid [, nSignal]` | `true` or `nil, sErr` |
| `process_yield` | 0-3 | — | `true` |
| `process_get_pid` | 0-3 | — | `nPid` |
| `process_get_ring` | 0-3 | — | `nRing` |
| `process_list` | 0-3 | — | `{pid, parent, ring, status, image}[]` |
| `process_elevate` | 3 | `nNewRing` | `true` or `nil, sErr` |

### 15.2 VFS Operations

| Syscall | Rings | Parameters | Returns |
|---------|-------|------------|---------|
| `vfs_open` | 0-3 | `sPath, sMode` | `true, sToken` or `nil, sErr` |
| `vfs_read` | 0-3 | `vHandle, nCount` | `true, sData` or `nil` |
| `vfs_write` | 0-3 | `vHandle, sData` | `true, nBytes` |
| `vfs_close` | 0-3 | `vHandle` | `true` |
| `vfs_list` | 0-3 | `sPath` | `true, tNames[]` |
| `vfs_delete` | 0-3 | `sPath` | `true` or `nil, sErr` |
| `vfs_mkdir` | 0-3 | `sPath` | `true` |
| `vfs_chmod` | 0-3 | `sPath, nMode` | `true` or `nil, sErr` |
| `vfs_device_control` | 0-3 | `vHandle, sMethod, tArgs` | `true, vResult` |
| `driver_load` | 0-3 | `sPath` | `true, sMsg` or `nil, sErr` |

### 15.3 Object Manager

| Syscall | Rings | Description |
|---------|-------|-------------|
| `ob_create_object` | 0-1 | Create a new kernel object |
| `ob_create_handle` | 0-1 | Mint a handle token |
| `ob_reference_by_handle` | 0-1 | Validate and retrieve object from handle |
| `ob_close_handle` | 0-1 | Close a handle |
| `ob_set_standard_handle` | 0-3 | Set stdin/stdout/stderr mapping |
| `ob_get_standard_handle` | 0-3 | Get stdin/stdout/stderr token |
| `ob_dump_directory` | 0-1 | List all kernel objects |

### 15.4 IPC / Synchronization

| Syscall | Rings | Description |
|---------|-------|-------------|
| `ke_create_event` | 0-3 | Create event object |
| `ke_set_event` / `ke_reset_event` | 0-3 | Signal / unsignal event |
| `ke_create_mutex` | 0-3 | Create mutex |
| `ke_release_mutex` | 0-3 | Release mutex |
| `ke_create_semaphore` | 0-3 | Create counting semaphore |
| `ke_release_semaphore` | 0-3 | Release semaphore permits |
| `ke_create_pipe` | 0-3 | Create anonymous pipe |
| `ke_create_named_pipe` | 0-3 | Create named pipe |
| `ke_wait_single` | 0-3 | Wait for one object |
| `ke_wait_multiple` | 0-3 | Wait for any/all objects |
| `ke_signal_send` | 0-3 | Send POSIX signal |
| `ke_signal_handler` | 0-3 | Register signal handler |
| `ke_create_section` | 0-3 | Create shared memory |
| `ke_create_mqueue` | 0-3 | Create message queue |
| `ke_mq_send` / `ke_mq_receive` | 0-3 | Send/receive messages |
| `ke_ipc_stats` | 0-3 | Get IPC subsystem statistics |

### 15.5 sMLTR

| Syscall | Rings | Description |
|---------|-------|-------------|
| `synapse_get_token` | 0-3 | Get own synapse token |
| `synapse_validate` | 0-2 | Validate a target's token |
| `synapse_rotate` | 0-1 | Rotate a process's token |

### 15.6 Registry

| Syscall | Rings | Description |
|---------|-------|-------------|
| `reg_create_key` | 0-2 | Create registry key |
| `reg_set_value` | 0-2 | Set value |
| `reg_get_value` | 0-3 | Get value (read-only for Ring 3) |
| `reg_enum_keys` | 0-3 | List subkeys |
| `reg_enum_values` | 0-3 | List values |
| `reg_dump_tree` | 0-3 | Get full tree structure |

---