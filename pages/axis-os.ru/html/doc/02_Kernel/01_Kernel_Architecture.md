# 2.1. Kernel Architecture

The AxisOS kernel, implemented in `kernel.lua`, is a monolithic entity responsible for the most critical system functions.

## The Scheduler

The kernel employs a simple, cooperative, round-robin scheduler. It maintains a master process table (`tProcessTable`) containing the state of every process in the system. In its main event loop, the scheduler iterates through all processes in the `ready` state and resumes their execution for one timeslice. A process voluntarily yields control back to the scheduler via the `kernel_yield` syscall or when it blocks on an I/O operation (e.g., `signal_pull`).

## Process Table and State Management

The `tProcessTable` is the single source of truth for process state. Each entry contains the process's coroutine, status (`ready`, `running`, `sleeping`, `dead`), privilege ring, parent PID, and a reference to its sandboxed environment.

## Event Handling

The kernel's main loop is driven by `computer.pullSignal()`. Raw hardware events are not processed directly by the kernel. Instead, they are packaged into an `os_event` signal and forwarded to the registered Ring 1 Pipeline Manager process for delegation to the appropriate driver or subsystem.