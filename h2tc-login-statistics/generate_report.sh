#!/usr/bin/env bash

# generate_report_top5.sh
# Connects to the MySQL database via a temporary Docker container, imports the uc_login_log.sql,
# and generates a localized Markdown report restricted to Top 10 successful logins, 
# and Top 10 Abnormal Login IPs (enhanced with Geolocation lookups via ip-api).

target_month=${1:-$(date +%Y%m)}
sql_file="uc_login_log.sql"
container_name="auto_uc_mysql"
output_file="report_top10_${target_month}.md"

# Check if SQL file is present
if [ ! -f "$sql_file" ]; then
    echo "错误: 当前目录下未找到 SQL 文件 '$sql_file'。"
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

start_time="${target_month}00000000"
end_time="${target_month}31235959"
CMD="docker exec -i $container_name mysql --default-character-set=utf8mb4 -uroot -proot uc -Bse "

# Function to get geolocation for an IP
get_geoloc() {
    local ip=$1
    if [[ "$ip" == "N/A" || -z "$ip" ]]; then
        echo "未知归属地"
        return
    fi
    # Use ip-api's free endpoint, limit 45 requests per minute which is fine for Top 10
    local loc
    loc=$(curl -s "http://ip-api.com/line/${ip}?fields=country,regionName,city,status&lang=zh-CN")
    local status=$(echo "$loc" | head -n 1)
    if [ "$status" = "success" ]; then
        local country=$(echo "$loc" | head -n 2 | tail -n 1)
        local region=$(echo "$loc" | head -n 3 | tail -n 1)
        local city=$(echo "$loc" | tail -n 1)
        
        # If it's a municipality (e.g. Beijing), region and city might be same or similar.
        # We can format it nicely:
        if [[ "$region" == *"$city"* || "$city" == *"$region"* ]]; then
            echo "${country} - ${region}"
        else
            echo "${country} - ${region} ${city}"
        fi
    else
        echo "未知归属地"
    fi
}

# Begin writing Markdown output
cat <<EOF > "$output_file"
# 登录统计核心简报：核心两强榜单

**统计月份:** $target_month  
**报告生成时间:** $(date +"%Y-%m-%d %H:%M:%S")

## 1. 用户活跃排行榜 (当月登录成功次数 Top 10)

| 用户ID | 登录账号 | 登录总次数 |
|---|---|---|
EOF

$CMD "
SELECT 
    IFNULL(USER_ID, 'N/A'), ACCOUNT, COUNT(1)
FROM uc_login_log 
WHERE OPERATOR_TYPE = 'loginO' 
  AND GMT_CREATE >= $start_time 
  AND GMT_CREATE <= $end_time
GROUP BY USER_ID, ACCOUNT 
ORDER BY COUNT(1) DESC 
LIMIT 5;
" 2>/dev/null | while read -r uid account count; do
    echo "| $uid | $account | $count |" >> "$output_file"
done

cat <<EOF >> "$output_file"

## 2. 异常登录 IP 排行榜 (防攻击/防暴破 Top 10)

| 异常登录IP | IP归属地 (国家/省市) | 异常次数 | 失败类型说明 |
|---|---|---|---|
EOF

echo ">> 正在解析异常登录 IP 的地理归属地..."
$CMD "
SELECT 
    IFNULL(LOGIN_IP, 'N/A'), COUNT(1), IFNULL(REMARK, 'N/A')
FROM uc_login_log
WHERE OPERATOR_TYPE = 'loginN'
GROUP BY LOGIN_IP, REMARK
ORDER BY COUNT(1) DESC
LIMIT 5;
" 2>/dev/null | while IFS=$'\t' read -r ip count reason; do
    geo=$(get_geoloc "$ip")
    echo "| $ip | $geo | $count | $reason |" >> "$output_file"
done

echo ">> 报表已成功生成。"

echo ">> 环境清理中... 正在移除临时 Docker 容器 ($container_name)..."
docker rm -f "$container_name" > /dev/null

echo ">> 完成！请在当前目录下查看结果文件: $output_file"
