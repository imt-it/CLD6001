# CLD6001 - Undergraduate Research Project

## Information

- Project Name: **Evaluation of Container Isolation and Security Posture in Enterprise Linux Operating Systems**
- Institute: **University of Bolton - Greater Manchester**
- Module: **CLD6001 - Undergraduate Research Project**
- Assessment: **Dissertation (Assessment 002)**
- Instructor: **Dr. Vasileios Anastopoulos**
- Supervisor: **Mr. Konstantinos Fouzas**
- Student: **Ioannis Marios Tsiakoulias**

---

## Description

This repository hosts the experimental framework and automated test harness for evaluating container isolation and security posture in Enterprise Linux operating systems. It compares three container runtimes — **Docker rootful**, **Docker rootless**, and **Podman rootless**, across two security profiles: **baseline defaults** and **CIS-aligned hardened**, on **RHEL/RHEL-compabile Operating Systems**.

The framework implements 24 test cases organised into 8 collections (A–H) covering privilege escalation, namespace manipulation, cgroup escapes, kernel exploits, SELinux enforcement, seccomp bypass, user namespaces, network isolation, supply chain security, and page-cache attack families (Copy Fail). Results are collected, normalised, and synthesised into a control-impact matrix and baseline recommendation.

---

## Core Features

- **Three-Runtime Comparison**: Automated execution across docker-rootful, docker-rootless, and podman-rootless in isolated VM environments.
- **CIS Hardening Pipeline**: Environment-state enforcement with baseline-system and cis-system lanes, including OpenSCAP remediation and Docker Bench audit.
- **Test Case Harness**: 24 packaged testcases under `src/test-cases/` with per-runtime adapters and legacy shim compatibility.
- **Collections A–H**: Logical grouping of testcases by attack family, with manifest-based execution control (ACTIVE, OPTIONAL, BLOCKED, EXPERIMENTAL, INACTIVE states).
- **Copy Fail Family**: TC22–TC24 implement bounded page-cache attack probes (CVE-2026-31431) with a reversible thesis-safe payload and manual-handoff mode for testing.
- **Evidence Collection**: Structured artifact capture, snapshot system, and synthesis gate for full-run vs partial-run export control.
- **Control-Impact Matrix**: Automated generation of runtime-specific control-impact matrices and baseline configuration recommendations.
- **Repository Automation**: Interactive menu (`run.sh`) for setup, testing, export, and maintenance; unattended full runs via `bash run.sh --non-interactive`.

---

## Requirements

- AlmaLinux 10.1 (kernel 6.12.x)
- Docker Engine (rootful and rootless)
- Podman (rootless)
- OpenSCAP, Docker Bench Security
- Python 3.x with standard library
- Bash 5.x, jq, and common UNIX tooling
- Minimum 2 vCPU, 4 GB RAM, 64 GB storage for full suite execution
