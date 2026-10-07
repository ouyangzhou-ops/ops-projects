-- MySQL 初始化脚本（max 服务器 192.168.194.135 执行）
-- 业务数据库与远程账号，供 Web 服务器连接
CREATE DATABASE IF NOT EXISTS webdb DEFAULT CHARSET utf8mb4;

-- 业务账号：仅允许 192.168.194.0/24 网段内的 Web 服务器连接
CREATE USER 'web'@'192.168.194.%' IDENTIFIED BY '<请替换为实际密码>';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'192.168.194.%';
FLUSH PRIVILEGES;
