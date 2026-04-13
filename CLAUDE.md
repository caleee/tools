# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains bash scripts for analyzing MySQL login logs from a `uc_login_log` table. The scripts import SQL dumps into a temporary Docker MariaDB container, run analytical queries, and generate Markdown reports.

## Key Scripts

All scripts are located in `h2tc-login-statistics/`:

| Script | Purpose |
|--------|---------|
| `generate_report.sh` | Generates concise Top 10 report with IP geolocation lookup (uses ip-api.com) |
| `generate_report_all.sh` | Generates full report with MAU/DAU trends, top users, and security analysis |
| `generate_report_full.sh` | Alias for `generate_report.sh` |

## Usage

```bash
cd h2tc-login-statistics

# Generate report for current month (default)
./generate_report.sh
./generate_report_all.sh

# Generate report for specific month
./generate_report.sh 202603
./generate_report_all.sh 202603
```

## Dependencies

- Docker (for temporary MariaDB container)
- curl (for IP geolocation API calls)
- Bash

## Data Schema

The `uc_login_log` table tracks user authentication events:

| Field | Description |
|-------|-------------|
| `USER_ID` | User identifier |
| `ACCOUNT` | Login account name |
| `OPERATOR_TYPE` | Event type: `loginO` (success), `loginN` (failed), `logoutO` (logout) |
| `REMARK` | Description (e.g., "用户登录成功", "用户登录密码错误") |
| `LOGIN_IP` | Source IP address |
| `GMT_CREATE` | Timestamp as decimal(14,0): YYYYMMDDHHMMSS |
| `LOGIN_SOURCE` | "web" or "app" |

## Output Files

- `report_YYYYMM.md` - Full statistical report (from `generate_report_all.sh`)
- `report_top10_YYYYMM.md` - Concise top 10 report with geolocation (from `generate_report.sh`)
