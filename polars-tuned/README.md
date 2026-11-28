# Polars High-Performance Tuned Runner

This directory contains the bare-metal optimized execution configuration for Polars. It enforces deep operating system and kernel isolation parameters to analyze processing saturation under strict non-caching criteria.

## System Tuning Properties
* **Core Separation:** Isolates physical compute cores strictly for framework processing threads via custom CPUset cgroup containment.
* **IRQ Routing:** Reroutes peripheral hardware interrupts entirely to Core 0 to achieve jitter-free evaluation hotpaths.
* **Power Management:** Overrides autonomous firmware throttling properties by forcing CPU frequencies to persistent maximum turbo thresholds.
