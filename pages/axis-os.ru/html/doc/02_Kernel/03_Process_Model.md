# 2.3. The Process Model and Lifecycle

A process in AxisOS is the fundamental unit of execution. Each process consists of a sandboxed Lua environment, a main coroutine, a unique Process ID (PID), and an associated privilege Ring.

## Process States

A process can exist in one of the following four states:

- **Ready**: The process is able to run but is currently waiting for the scheduler to grant it a timeslice.
- **Running**: The process is currently executing on the CPU. Only one process can be in this state at any given time.
- **Sleeping**: The process is blocked, waiting for an event to occur. This can be an incoming IPC signal (`signal_pull`), the termination of a child process (`process_wait`), or the completion of an asynchronous I/O operation. A sleeping process consumes no CPU resources.
- **Dead**: The process has finished execution, either by returning from its main function or by being terminated due to an error or violation. Dead processes are eventually garbage collected by the system.
