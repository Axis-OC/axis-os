    
# AxisOS Technical Documentation

## Table of Contents

### Part I: Core Concepts
*   **[1. Introduction](./01_Introduction/01_Architectural_Overview.md)**
    *   [1.1. Architectural Overview](./01_Introduction/01_Architectural_Overview.md)
    *   [1.2. Core Design Philosophies](./01_Introduction/02_Core_Philosophies.md)

### Part II: The Kernel
*   **[2. The AxisOS Kernel](./02_Kernel/01_Kernel_Architecture.md)**
    *   [2.1. Kernel Architecture](./02_Kernel/01_Kernel_Architecture.md)
    *   [2.2. The Boot Sequence](./02_Kernel/02_Boot_Sequence.md)
    *   [2.3. The Process Model and Lifecycle](./02_Kernel/03_Process_Model.md)

### Part III: System Programming Interfaces
*   **[3. The System Call Interface](./03_System_Calls/README.md)**
*   **[4. The AxisOS Driver Model (ADM)](./04_Driver_Model_ADM/README.md)**
    *   [4.1. Kernel-Mode Driver Framework (KMDF) Reference](./04_Driver_Model_ADM/01_KMDF_Reference.md)
    *   [4.2. User-Mode Driver Framework (UMDF) Reference](./04_Driver_Model_ADM/02_UMDF_Reference.md)

### Part IV: Subsystems
*   **[5. The Virtual File System (VFS) and I/O Subsystem](./05_VFS_and_IO/01_VFS_Architecture.md)**
    *   [5.1. VFS Architecture](./05_VFS_and_IO/01_VFS_Architecture.md)
    *   [5.2. The I/O Request Flow](./05_VFS_and_IO/02_IO_Request_Flow.md)

### Part V: The User Environment
*   **[6. User Space](./06_User_Space/01_Init_Process.md)**
    *   [6.1. The `init` Process (PID 1)](./06_User_Space/01_Init_Process.md)
    *   [6.2. Standard Libraries](./06_User_Space/02_Standard_Libraries.md)
    *   [6.3. The Shell and Execution Environment](./06_User_Space/03_Shell_and_Execution_Environment.md)

### Part VI: Security
*   **[7. The AxisOS Security Model](./07_Security/01_Ring_Model.md)**
    *   [7.1. The Ring Model](./07_Security/01_Ring_Model.md)
    *   [7.2. Process Sandboxing](./07_Security/02_Process_Sandboxing.md)

  