## 16. Error Codes

### 16.1 Status Code Table

| Code | Name | Description |
|------|------|-------------|
| `0` | `STATUS_SUCCESS` | Operation completed successfully |
| `1` | `STATUS_PENDING` | Operation in progress |
| `258` | `STATUS_TIMEOUT` | Wait operation timed out |
| `300` | `STATUS_UNSUCCESSFUL` | General failure |
| `301` | `STATUS_NOT_IMPLEMENTED` | Feature not implemented |
| `400` | `STATUS_INVALID_DRIVER_OBJECT` | Malformed driver object |
| `401` | `STATUS_INVALID_DRIVER_ENTRY` | Missing DriverEntry function |
| `402` | `STATUS_INVALID_DRIVER_INFO` | Missing or invalid g\_tDriverInfo |
| `403` | `STATUS_DRIVER_VALIDATION_FAILED` | Signature or security check failed |
| `404` | `STATUS_DRIVER_INIT_FAILED` | DriverEntry returned error |
| `405` | `STATUS_NO_SUCH_DEVICE` | Device not found in tree |
| `406` | `STATUS_DEVICE_ALREADY_EXISTS` | Duplicate device name |
| `407` | `STATUS_INVALID_DRIVER_TYPE` | Unknown driver type |
| `500` | `STATUS_ACCESS_DENIED` | Permission denied |
| `501` | `STATUS_PRIVILEGE_NOT_HELD` | Higher ring required |
| `502` | `STATUS_SYNAPSE_TOKEN_MISMATCH` | sMLTR token invalid |
| `600` | `STATUS_INVALID_HANDLE` | Handle not found or expired |
| `601` | `STATUS_INVALID_PARAMETER` | Bad argument |
| `602` | `STATUS_END_OF_FILE` | No more data |
| `604` | `STATUS_DEVICE_BUSY` | Device processing another request |
| `700` | `STATUS_HANDLE_NOT_FOUND` | Handle token not in table |

---
