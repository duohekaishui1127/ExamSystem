# LAN Exam System Portable V0.1.0

这是一个面向非技术人员的小型 Windows 局域网考试系统。
- 源码包含：
  - `server.ps1`：PowerShell/.NET 局域网后端
  - `web/admin.html`：管理员端
  - `web/user.html`：成员端
  - `QUESTION_IMPORT_TEMPLATE.xlsx`：Excel 题目导入模板
  - `QUESTION_IMPORT_TEMPLATE.csv`：CSV 题目导入模板
  - `START_SERVER.bat`：Windows 一键启动脚本
- Windows PowerShell 5.1 兼容逻辑、自动防火墙处理、历史考试、人工改判、题目导入、重新测验等功能均保留。

## 启动

管理员只需要一个入口：

`START_SERVER.bat`

双击后系统会：

1. 自动检查 TCP 8080 的局域网防火墙规则；
2. 首次需要时自动请求 Windows 管理员权限添加规则；
3. 启动局域网考试服务；
4. 自动打开管理员后台；
5. 在窗口中显示成员访问地址。

成员电脑无需安装任何环境，只需使用 Edge / Chrome 打开管理员提供的局域网地址。

## 默认账号

- 管理员用户名：`admin`
- 管理员密码：`admin123`
- 默认考试口令：`123456`

建议第一次登录后修改管理员密码。