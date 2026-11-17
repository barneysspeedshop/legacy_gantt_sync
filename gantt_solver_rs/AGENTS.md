# AI Agent Instructions for Rust Solver

This package contains `gantt_solver_rs`, a Rust-based computational engine that handles complex constraints, recalculating Critical Paths, and optimizing timeline layouts.

## Build and CI Constraints

> [!WARNING]
> Ensure any new Rust dependencies or significant architectural changes accommodate resource constraints.
>
> **Docker Swarm 1GB Memory Limit**
> The `legacy_gantt_sync` ecosystem is deployed to Oracle Docker Swarm instances with strict 1GB limitations. 
> In the past, trying to compile the Rust solver concurrently or within massive un-pruned Docker build contexts has caused out-of-memory errors and pipeline failures.
>
> If you are modifying the Docker build process, ensure you:
> 1. Use sequential build steps for the rust binary.
> 2. Implement strict `.dockerignore` context pruning to keep the image slim.
> 3. Utilize aggressive build caches to maintain stability.
