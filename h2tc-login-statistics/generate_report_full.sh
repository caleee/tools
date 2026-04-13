#!/usr/bin/env bash

# generate_report_full.sh
# Connects to the MySQL database via a temporary Docker container, imports uc_login_log_full.sql,
# and generates a localized Markdown report with user-IP-geolocation mapping.
#
# Usage:
#   ./generate_report_full.sh              # 全量数据
#   ./generate_report_full.sh 202603       # 指定月份
#   ./generate_report_full.sh 7d           # 最近7天
#   ./generate_report_full.sh 20260301 20260315  # 日期区间 YYYYMMDD YYYYMMDD

date_mode="all"
start_time=""
end_time=""
output_suffix="all"

# Parse arguments
if [ $# -eq 0 ]; then
    # 全量模式
    date_mode="all"
    output_suffix="all"
elif [ $# -eq 1 ]; then
    if [[ "$1" == "7d" ]]; then
        # 最近7天
        date_mode="7d"
        end_time=$(date +%Y%m%d%H%M%S)
        # macOS/Linux 兼容
        if date -v-7d +%Y%m%d%H%M%S >/dev/null 2>&1; then
            start_time=$(date -v-7d +%Y%m%d%H%M%S)
        else
            start_time=$(date -d "7 days ago" +%Y%m%d%H%M%S)
        fi
        output_suffix="7d"
    elif [[ "$1" =~ ^[0-9]{6}$ ]]; then
        # 指定月份 YYYYMM
        date_mode="month"
        target_month="$1"
        start_time="${target_month}00000000"
        end_time="${target_month}31235959"
        output_suffix="${target_month}"
    else
        echo "错误: 参数格式不正确"
        echo "用法:"
        echo "  $0              # 全量数据"
        echo "  $0 202603       # 指定月份"
        echo "  $0 7d           # 最近7天"
        echo "  $0 20260301 20260315  # 日期区间"
        exit 1
    fi
elif [ $# -eq 2 ]; then
    # 日期区间
    if [[ "$1" =~ ^[0-9]{8}$ ]] && [[ "$2" =~ ^[0-9]{8}$ ]]; then
        date_mode="range"
        start_time="${1}000000"
        end_time="${2}235959"
        output_suffix="${1}_${2}"
    else
        echo "错误: 日期格式应为 YYYYMMDD"
        exit 1
    fi
else
    echo "错误: 参数过多"
    exit 1
fi

sql_file="tools/h2tc-login-statistics/uc_login_log_full.sql"
container_name="auto_uc_mysql"
output_file="report_user_ip_${output_suffix}.md"

# Check if SQL file is present (try relative to current dir, then parent dir)
if [ ! -f "$sql_file" ]; then
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    sql_file="${script_dir}/uc_login_log_full.sql"
fi

if [ ! -f "$sql_file" ]; then
    echo "错误: 未找到 SQL 文件 '$sql_file'。"
    exit 1
fi

echo ">> 正在启动临时 MariaDB 容器 ($container_name)..."
docker run --name "$container_name" -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=uc -p 33061:3306 -d mariadb:10.3 > /dev/null

echo ">> 等待数据库初始化完成 (通常少于20秒)..."
until docker exec "$container_name" mysqladmin ping -h localhost --silent; do
    sleep 2
done

echo ">> 正在将 '$sql_file' 导入到临时数据库中..."
docker exec -i "$container_name" mysql -uroot -proot uc < "$sql_file"

echo ">> 数据库准备就绪，正在生成分析报表 '$output_file'..."

CMD="docker exec -i $container_name mysql --default-character-set=utf8mb4 -uroot -proot uc -Bse "

# Use temp file for IP cache
ip_cache_file="/tmp/ip_cache_$$.txt"
touch "$ip_cache_file"

# Cleanup cache on exit
trap "rm -f $ip_cache_file" EXIT

# Function to get geolocation for an IP
get_geoloc() {
    local ip=$1
    if [[ "$ip" == "N/A" || -z "$ip" ]]; then
        echo "未知归属地"
        return
    fi
    # Check cache first
    local cached
    cached=$(grep "^${ip}|" "$ip_cache_file" 2>/dev/null | cut -d'|' -f2)
    if [[ -n "$cached" ]]; then
        echo "$cached"
        return
    fi
    # Use ip-api's free endpoint, limit 45 requests per minute
    local loc
    loc=$(curl -s "http://ip-api.com/line/${ip}?fields=country,regionName,city,status&lang=zh-CN")
    local status=$(echo "$loc" | head -n 1)
    local result
    if [ "$status" = "success" ]; then
        local country=$(echo "$loc" | head -n 2 | tail -n 1)
        local region=$(echo "$loc" | head -n 3 | tail -n 1)
        local city=$(echo "$loc" | tail -n 1)

        # If it's a municipality (e.g. Beijing), region and city might be same or similar.
        if [[ "$region" == *"$city"* || "$city" == *"$region"* ]]; then
            result="${country} - ${region}"
        else
            result="${country} - ${region} ${city}"
        fi
    else
        result="未知归属地"
    fi
    # Cache the result
    echo "${ip}|${result}" >> "$ip_cache_file"
    echo "$result"
}

# Build date filter for SQL
if [ "$date_mode" == "all" ]; then
    date_filter=""
    date_desc="全量数据"
elif [ "$date_mode" == "7d" ]; then
    date_filter="AND GMT_CREATE >= $start_time AND GMT_CREATE <= $end_time"
    date_desc="最近7天 ($start_time ~ $end_time)"
else
    date_filter="AND GMT_CREATE >= $start_time AND GMT_CREATE <= $end_time"
    date_desc="$start_time ~ $end_time"
fi

# Begin writing Markdown output
cat <<EOF > "$output_file"
# 用户登录 IP 归属地统计报表

**统计范围:** $date_desc
**报告生成时间:** $(date +"%Y-%m-%d %H:%M:%S")

## 用户登录 IP 及归属地明细

| 用户ID | 登录账号 | 登录IP | IP归属地 | 登录次数 |
|---|---|---|---|---|
EOF

echo ">> 正在查询用户登录数据并解析 IP 归属地..."

# Query: get unique user-IP combinations with count
$CMD "
SELECT
    IFNULL(USER_ID, 'N/A') as uid,
    IFNULL(ACCOUNT, 'N/A') as account,
    IFNULL(LOGIN_IP, 'N/A') as ip,
    COUNT(1) as cnt
FROM uc_login_log
WHERE OPERATOR_TYPE = 'loginO'
  $date_filter
GROUP BY USER_ID, ACCOUNT, LOGIN_IP
ORDER BY uid, cnt DESC;
" 2>/dev/null | while IFS=$'\t' read -r uid account ip count; do
    geo=$(get_geoloc "$ip")
    echo "| $uid | $account | $ip | $geo | $count |" >> "$output_file"
done

cat <<EOF >> "$output_file"

---
*说明：同一用户可能在多个地点登录，表格按用户ID排序，同一用户下按登录次数降序排列*
EOF

echo ">> 报表已成功生成。"

echo ">> 环境清理中... 正在移除临时 Docker 容器 ($container_name)..."
docker rm -f "$container_name" > /dev/null

echo ">> 完成！请在当前目录下查看结果文件: $output_file"
