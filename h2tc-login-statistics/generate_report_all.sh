#!/usr/bin/env bash

# generate_report.sh
# Connects to the MySQL database via a temporary Docker container, imports the uc_login_log.sql,
# and generates user login statistics in Markdown format for a specific month.
# Usage: ./generate_report.sh [YYYYMM]
# Example: ./generate_report.sh 202601

target_month=${1:-$(date +%Y%m)}
sql_file="uc_login_log.sql"
container_name="auto_uc_mysql"
output_file="report_${target_month}.md"

# Check if SQL file is present
if [ ! -f "$sql_file" ]; then
    echo "Error: SQL file '$sql_file' not found in the current directory."
    exit 1
fi

echo ">> 正在启动临时 MariaDB 容器 ($container_name)..."
# Start the container
docker run --name "$container_name" -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=uc -p 33061:3306 -d mariadb:10.3 > /dev/null

# Wait for the database to be ready
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

# Begin writing Markdown output
cat <<EOF > "$output_file"
# 用户登录统计报表

**统计月份:** $target_month  
**报告生成时间:** $(date +"%Y-%m-%d %H:%M:%S")

## 1. 默认按照月份统计总成功次数及月活跃用户 (MAU)
EOF

output=$($CMD "SELECT COUNT(1), COUNT(DISTINCT USER_ID) FROM uc_login_log WHERE OPERATOR_TYPE = 'loginO' AND GMT_CREATE >= $start_time AND GMT_CREATE <= $end_time;" 2>/dev/null)
total=$(echo "$output" | awk '{print $1}')
mau=$(echo "$output" | awk '{print $2}')

cat <<EOF >> "$output_file"
* **当月总计登录成功次数:** $total
* **独立活跃用户数 (MAU):** $mau

## 2. 具体的用户登录成功月活量排序（前十名）

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
LIMIT 10;
" 2>/dev/null | while read -r uid account count; do
    echo "| $uid | $account | $count |" >> "$output_file"
done

cat <<EOF >> "$output_file"

## 3. 近期按月份统计系统的月活跃登录量趋势 (DAU / MAU)

| 统计月份 | 日志总登录人次 | 独立活跃用户数(MAU) |
|---|---|---|
EOF

$CMD "
SELECT 
    SUBSTRING(CAST(GMT_CREATE AS CHAR), 1, 6), COUNT(1), COUNT(DISTINCT USER_ID)
FROM uc_login_log 
WHERE OPERATOR_TYPE = 'loginO' 
GROUP BY SUBSTRING(CAST(GMT_CREATE AS CHAR), 1, 6)
ORDER BY SUBSTRING(CAST(GMT_CREATE AS CHAR), 1, 6) DESC
LIMIT 6;
" 2>/dev/null | while read -r month count mau; do
    echo "| $month | $count | $mau |" >> "$output_file"
done

cat <<EOF >> "$output_file"

## 4. 统计每个 IP 的异常登录次数（排查刷接口或者被攻击记录 - 前十名）

| 异常登录IP | 异常次数 | 失败类型说明 |
|---|---|---|
EOF

$CMD "
SELECT 
    IFNULL(LOGIN_IP, 'N/A'), COUNT(1), IFNULL(REMARK, 'N/A')
FROM uc_login_log
WHERE OPERATOR_TYPE = 'loginN'
GROUP BY LOGIN_IP, REMARK
ORDER BY COUNT(1) DESC
LIMIT 10;
" 2>/dev/null | while IFS=$'\t' read -r ip count reason; do
    echo "| $ip | $count | $reason |" >> "$output_file"
done

cat <<EOF >> "$output_file"

## 5. 特定异常类型中频繁被攻击的账号及来源 IP（前十名）

| 攻击源IP | 尝试破解的账号 | 尝试失败次数 |
|---|---|---|
EOF

$CMD "
SELECT 
    IFNULL(LOGIN_IP, 'N/A'), IFNULL(ACCOUNT, 'N/A'), COUNT(1)
FROM uc_login_log
WHERE OPERATOR_TYPE = 'loginN'
GROUP BY LOGIN_IP, ACCOUNT
ORDER BY COUNT(1) DESC
LIMIT 10;
" 2>/dev/null | while IFS=$'\t' read -r ip account count; do
    echo "| $ip | $account | $count |" >> "$output_file"
done

echo ">> 报表已成功生成。"

echo ">> 环境清理中... 正在移除临时 Docker 容器 ($container_name)..."
docker rm -f "$container_name" > /dev/null

echo ">> 完成！请在当前目录下查看结果文件: $output_file"
