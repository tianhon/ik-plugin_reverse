---
name: sysinfo
description: Get the recent system information and logs of this machine.
homepage: ""
metadata: {"nanobot":{"emoji":"📄","requires":{"bins":["sqlite3"]}}}
---

# When to use

Use this skill when the user asks for:
- recent system logs / 系统日志
- system event logs / 事件日志 / 线路检测日志
- admin operation logs / 管理员操作日志 / web 登录日志
- recent activities or events on the iKuai router

Always return only the **most recent 20 entries** — never show the entire log history.

Do NOT attempt to read or display the full database.  
Do NOT modify, delete, or write to the database.

## Recommended queries

### 1. Recent system event logs (线路检测、接口状态等)

```bash
DB="/etc/mnt/plugins/configs/picoclaw/workspace/iksysinfo/syslog.db"

if [ ! -f "$DB" ]; then
  echo "Error: Database file not found: $DB"
  exit 1
fi

sqlite3 "$DB" "
  SELECT 
    datetime(timestamp, 'unixepoch', 'localtime') AS time,
    content
  FROM sys_event 
  ORDER BY timestamp DESC 
  LIMIT 20;
" 2>/dev/null || echo "Error: Failed to query system event logs"
```

### 2. Recent web admin operation logs (管理员操作记录)

```bash
DB="/etc/mnt/plugins/configs/picoclaw/workspace/iksysinfo/syslog.db"

if [ ! -f "$DB" ]; then
  echo "Error: Database file not found: $DB"
  exit 1
fi

sqlite3 "$DB" "
  SELECT 
    datetime(timestamp, 'unixepoch', 'localtime') AS time,
    username,
    ip_addr,
    function,
    event
  FROM webadmin 
  ORDER BY timestamp DESC 
  LIMIT 20;
" 2>/dev/null || echo "Error: Failed to query webadmin logs"
```

## Output guidelines for the AI
- Convert the raw output into a clean markdown table
- Use readable column names (时间 / 用户 / IP / 功能 / 操作 等)
- If query fails or returns empty, clearly tell the user: “无法读取系统日志。”
- Keep response concise, only show the latest 20 records
- Do not explain the SQL or internal paths unless user explicitly asks about skill implementation
