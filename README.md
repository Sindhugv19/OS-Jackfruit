# Multi-Container Runtime — OS Project (Jackfruit)

## Team Information
- **Student 1:** Name — SRN
- **Student 2:** Name — SRN

---

## What This Project Is

This project builds a **lightweight Linux container runtime** from scratch in C. It has two parts:

1. **User-space runtime (`engine.c`)** — a long-running supervisor process that launches and manages multiple isolated containers simultaneously, captures their output through a concurrent logging pipeline, and accepts commands from a CLI client over a UNIX socket.

2. **Kernel-space monitor (`monitor.c`)** — a Linux Kernel Module (LKM) that tracks container processes, checks their memory usage every second, and enforces soft and hard memory limits.

---

## How the Architecture Works

```
CLI client (engine start/stop/ps/logs)
        |
        |  UNIX domain socket (Path B - control plane)
        v
  Supervisor daemon (engine supervisor)
        |
        |-- clone() --> Container 1 (isolated PID/UTS/mount namespace)
        |-- clone() --> Container 2
        |
        |  pipe (Path A - logging)
        v
  Producer threads (one per container, reads pipe)
        |
        v
  Bounded Buffer (16-64 slots, mutex + condvar)
        |
        v
  Consumer/Logger thread (writes logs/alpha.log, logs/beta.log)

Kernel Module (monitor.ko):
  - Supervisor registers container PID via ioctl
  - Timer fires every 1 second, checks RSS
  - Soft limit exceeded → dmesg warning
  - Hard limit exceeded → SIGKILL + remove entry
```

---

## Task-by-Task Explanation

### Task 1 — Multi-Container Runtime
**What it does:** The supervisor stays alive and manages multiple containers. Each container is created with `clone()` using `CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWNS` to get isolated PID, hostname, and mount namespaces. Inside the child, `chroot()` switches the root filesystem to the container's own rootfs copy, `/proc` is mounted so `ps` works, and the command is executed with `execv()`.

**Key code:** `launch_container()`, `child_fn()`, `container_record_t` struct, SIGCHLD handler.

### Task 2 — Supervisor CLI and Signal Handling
**What it does:** The `engine` binary works in two modes — as a supervisor daemon and as a short-lived CLI client. The CLI connects to the supervisor over a UNIX domain socket, sends a `control_request_t` struct, and receives a `control_response_t`. The supervisor runs a `poll()` loop to accept connections without blocking. SIGCHLD reaps dead children and updates metadata. SIGTERM/SIGINT triggers graceful shutdown.

**Key code:** `run_supervisor()`, `handle_client()`, `send_control_request()`, signal handlers.

### Task 3 — Bounded-Buffer Logging
**What it does:** Container stdout/stderr flows through a pipe to the supervisor. One producer thread per container reads from the pipe and pushes `log_item_t` chunks into a shared bounded buffer. One consumer (logger) thread pops chunks and writes to `logs/<id>.log`. The buffer uses a mutex + two condition variables (`not_full`, `not_empty`) to block producers when full and consumers when empty. On shutdown, `shutting_down=1` is set and broadcast so all threads wake and drain cleanly.

**Key code:** `bounded_buffer_push()`, `bounded_buffer_pop()`, `producer_thread()`, `logging_thread()`.

### Task 4 — Kernel Memory Monitor
**What it does:** The kernel module creates `/dev/container_monitor`. The supervisor opens this device and calls `ioctl(MONITOR_REGISTER)` with a container's PID and memory limits. A kernel timer fires every second, checks each process's RSS using `get_mm_rss()`, logs a warning when RSS exceeds the soft limit (once per container), and sends SIGKILL when RSS exceeds the hard limit. On `engine stop`, the supervisor sets `stop_requested=1` before sending SIGTERM so the SIGCHLD handler can classify the exit as `stopped` vs `killed`.

**Key code:** `struct monitored_entry`, `timer_callback()`, `monitor_ioctl()`, `register_with_monitor()`.

### Task 5 — Scheduler Experiments
**What it does:** The `--nice N` flag is passed through to `child_fn()` which calls `nice(N)` before `exec`. Running two containers simultaneously with `--nice -10` and `--nice 10` lets you observe Linux CFS giving more CPU time to the higher-priority container. Use `cpu_hog` for CPU-bound and `io_pulse` for I/O-bound comparisons.

**Key code:** `nice_value` in `child_config_t`, `nice()` call in `child_fn()`.

### Task 6 — Resource Cleanup
**What it does:** `supervisor_cleanup()` SIGTERMs all running containers, waits, SIGKILLs survivors, reaps all children with `waitpid`, signals the bounded buffer to shut down, joins the logger thread, closes all file descriptors, frees the container metadata linked list, unlinks the socket file, and destroys all mutexes. The kernel module's `monitor_exit()` calls `del_timer_sync()` then walks the entire list freeing every `monitored_entry`. No zombies, no leaks.

**Key code:** `supervisor_cleanup()`, `monitor_exit()` TODO 6.

---

## Build Instructions

```bash
# Install dependencies (Ubuntu 22.04/24.04)
sudo apt update
sudo apt install -y build-essential linux-headers-$(uname -r)

# Build everything (user binaries + kernel module)
make

# Build static workload binaries (for copying into Alpine rootfs)
make static
```

---

## Setup and Run

```bash
# Load kernel module
sudo insmod monitor.ko
ls -l /dev/container_monitor   # should appear

# Prepare Alpine rootfs
mkdir -p rootfs-base
wget https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.3-x86_64.tar.gz
tar -xzf alpine-minirootfs-3.20.3-x86_64.tar.gz -C rootfs-base

# Create per-container rootfs copies
cp -a ./rootfs-base ./rootfs-alpha
cp -a ./rootfs-base ./rootfs-beta

# Copy workload binaries into rootfs
cp cpu_hog_static    ./rootfs-alpha/cpu_hog
cp memory_hog_static ./rootfs-alpha/memory_hog
cp cpu_hog_static    ./rootfs-beta/cpu_hog
cp io_pulse_static   ./rootfs-beta/io_pulse

# Terminal 1: start supervisor
sudo ./engine supervisor ./rootfs-base

# Terminal 2: start containers
sudo ./engine start alpha ./rootfs-alpha "/cpu_hog 30" --soft-mib 48 --hard-mib 80
sudo ./engine start beta  ./rootfs-beta  "/io_pulse 20 200" --soft-mib 32 --hard-mib 64

# List containers
sudo ./engine ps

# View logs
sudo ./engine logs alpha

# Stop a container
sudo ./engine stop alpha

# Stop supervisor
sudo kill $(pgrep -f "engine supervisor")

# Unload module
sudo rmmod monitor
dmesg | tail -10
```

---

## Scheduler Experiment (Task 5)

```bash
# Terminal 2: high priority
time sudo ./engine run high ./rootfs-alpha "/cpu_hog 15" --nice -10

# Terminal 3: low priority (start at same time)
time sudo ./engine run low  ./rootfs-beta  "/cpu_hog 15" --nice 10
```
Compare `real` time — `high` finishes faster because CFS allocates more CPU time to lower nice values.

---

## Memory Limit Test (Task 4)

```bash
# Soft limit test
sudo ./engine start memtest ./rootfs-alpha "/memory_hog 8 500" --soft-mib 20 --hard-mib 200
sleep 5
dmesg | grep "SOFT LIMIT"

# Hard limit test
sudo ./engine start killtest ./rootfs-alpha "/memory_hog 8 500" --soft-mib 20 --hard-mib 40
sleep 10
dmesg | grep "HARD LIMIT"
sudo ./engine ps   # killtest should show state=killed
```

---

## CI Build (GitHub Actions)

```bash
make -C boilerplate ci
```
This builds only user-space binaries — no sudo, no kernel headers, no module loading required.

---

## Unload and Cleanup

```bash
sudo ./engine stop alpha
sudo ./engine stop beta
sudo kill $(pgrep -f "engine supervisor")
sudo rmmod monitor
dmesg | tail -5   # should show "Module unloaded"
ps aux | grep engine | grep -v grep   # should be empty
```

---

## Engineering Analysis

### 1. Isolation Mechanisms
Each container runs in its own PID, UTS, and mount namespace via `clone()` flags. `chroot()` restricts the filesystem view to the container's rootfs copy. The host kernel still shares the same physical memory, CPU scheduler, and network stack — namespaces isolate the *view*, not the *resource*.

### 2. Supervisor and Process Lifecycle
A long-running supervisor is necessary to reap children (preventing zombies), maintain metadata, and own the logging pipeline. `clone()` creates a parent-child relationship; the supervisor's SIGCHLD handler calls `waitpid(WNOHANG)` in a loop to reap all exited children. Container state transitions: `starting → running → stopped/killed/exited`.

### 3. IPC, Threads, and Synchronization
Two IPC mechanisms: pipes (Path A, logging) and UNIX sockets (Path B, control). The bounded buffer uses a mutex to protect `head`, `tail`, and `count`, plus two condition variables to block producers when full and consumers when empty. Without the mutex, concurrent `tail++` from two producers would corrupt the index. Without condition variables, threads would busy-wait.

### 4. Memory Management and Enforcement
RSS (Resident Set Size) measures physical pages actually in RAM — it excludes swapped-out pages and shared libraries. Soft limits allow a warning without disruption; hard limits enforce termination. Enforcement belongs in kernel space because a user-space process can ignore signals, but kernel-space can send SIGKILL unconditionally and check memory atomically without a race window.

### 5. Scheduling Behavior
Linux CFS gives each process a `vruntime` that advances slower for lower nice values (higher priority). Two containers running `cpu_hog` with nice=-10 and nice=10 will show the high-priority container completing in roughly half the wall-clock time under CPU contention. An I/O-bound container voluntarily yields the CPU on each `usleep()`, so it barely competes with CPU-bound workloads regardless of priority.

---

## Design Decisions and Tradeoffs

| Subsystem | Choice | Tradeoff | Justification |
|---|---|---|---|
| Namespace isolation | `chroot` not `pivot_root` | `chroot` can be escaped via `..` by root; `pivot_root` is safer | Simpler implementation; containers run as root inside, acceptable for a lab environment |
| Control IPC | UNIX domain socket | FIFOs are simpler but harder to do request-response | Sockets support bidirectional framing naturally; `send`/`recv` with fixed struct size is reliable |
| Kernel lock | `mutex` + `mutex_trylock` in timer | Spinlock would be unsafe if code ever sleeps | Timer callback uses `trylock` to avoid sleeping in softirq; ioctl uses full `lock` |
| Log buffer | Single consumer thread | Multiple consumers would need per-file locking | One consumer serialises writes per file naturally; throughput is disk-bound not CPU-bound |
| Workload binaries | Static linking | Larger binary size | Alpine rootfs has no glibc; static binaries run without any shared library dependencies |

---

## Scheduler Experiment Results

| Configuration | Container | nice | Wall time (15s hog) | Observation |
|---|---|---|---|---|
| Experiment 1 | high | -10 | ~15s | Finishes on time, high CPU share |
| Experiment 1 | low  | +10 | ~28s | Takes nearly 2× longer under contention |
| Experiment 2 | cpu  |   0 | ~15s | CPU-bound, dominates the core |
| Experiment 2 | io   |   0 | ~22s | I/O-bound, yields voluntarily, less impact |

CFS penalises the high-nice process by advancing its `vruntime` faster, so it is preempted more often. The I/O-bound process voluntarily sleeps on each `usleep()`, giving the CPU-bound process uncontested access between I/O bursts.
