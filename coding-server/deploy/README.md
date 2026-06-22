# coding-server 部署到公网服务器

把中转服务器从你 Mac(CGNAT 后面,只能走 Tailscale 中继、又慢又不稳)搬到一台有
**公网 IP** 的云服务器。之后手机和电脑端都是**主动出站**连这台服务器,NAT 不再挡路,
直连、快、稳,连 Tailscale 都能省掉。

## 包里有什么

| 文件 | 用途 |
|---|---|
| `coding-server.jar` | Spring Boot 胖包,内置 Tomcat(8080)+ Netty 中转 WS(8090) |
| `application.properties` | 外置配置,改端口/Google client-id 不用重新打包 |
| `run.sh` | 简易启停脚本(快速试跑用) |
| `coding-server.service` | systemd 服务(生产推荐,开机自启 + 崩溃自拉) |
| `README.md` | 本文件 |

## 服务器要求

- Linux(Ubuntu/Debian/CentOS 都行),**1 核 512MB 内存**足矣(JVM 限了 256MB)
- **Java 17+**(JRE 即可):
  - Ubuntu/Debian: `sudo apt update && sudo apt install -y openjdk-17-jre-headless`
  - CentOS/Alma: `sudo yum install -y java-17-openjdk`
  - 验证: `java -version` 要显示 17 或更高
- 放开端口 **8080** 和 **8090**(见下「防火墙」)

## 部署步骤

### 1. 上传

把整个 `deploy` 目录(或下面的 `coding-server-deploy.tar.gz`)传到服务器,例如解压到 `/opt/coding-server`:

```bash
# 本地:用 scp 上传(把 1.2.3.4 换成你服务器 IP)
scp coding-server-deploy.tar.gz root@1.2.3.4:/opt/

# 服务器上:
cd /opt && tar -xzf coding-server-deploy.tar.gz && mv deploy coding-server && cd coding-server
```

### 2. 跑起来

**方式 A:快速试跑(run.sh)**
```bash
chmod +x run.sh
./run.sh start      # 后台启动
./run.sh log        # 看日志(Ctrl+C 退出查看,不影响运行)
./run.sh status     # 看状态
./run.sh stop       # 停
```
看到日志里 `Tomcat started on port 8080` 和 Netty `中转 WS 监听` 即成功。

**方式 B:systemd(生产推荐,开机自启 + 崩了自动重启)**
```bash
# 改 coding-server.service 里的 User 和 WorkingDirectory 为实际值
sudo cp coding-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now coding-server
sudo systemctl status coding-server      # 看状态
sudo journalctl -u coding-server -f       # 看日志
```

### 3. 防火墙 / 安全组(关键,最容易漏)

云服务器一般有**两层**防火墙,都要放开 8080、8090:

- **云控制台「安全组」**:在阿里云/腾讯云/AWS 控制台,给实例的安全组加入站规则:TCP 8080、TCP 8090,来源 0.0.0.0/0
- **服务器系统防火墙**:
  ```bash
  # ufw(Ubuntu)
  sudo ufw allow 8080/tcp && sudo ufw allow 8090/tcp
  # firewalld(CentOS)
  sudo firewall-cmd --permanent --add-port=8080/tcp --add-port=8090/tcp && sudo firewall-cmd --reload
  ```

验证(本地电脑上):
```bash
curl http://1.2.3.4:8080/api/app/version   # 应返回 JSON
```

### 4. 把手机和电脑端指向新服务器

- **手机**:App 设置页 → 服务器 IP 填 `1.2.3.4`、端口 `8090` → 保存并重连
- **电脑端(VibeNotch)**:目前服务器地址是写死的 `127.0.0.1`,搬到 VPS 后需要改成可配置 —— 这块代码改动让 Claude 帮你做(改完你在 VibeNotch 设置里填 VPS IP 即可)

## 数据 / 账号迁移(可选)

服务器把账号、token、图片都存在工作目录的 `data/` 下:
- `data/users.json`、`data/tokens.json` —— 账号和登录令牌
- `data/images/` —— 图片中转缓存(24h 自动清)

**全新 VPS = 全新账号**:直接在新服务器上重新用 Google 登录建号、设密码、重新配对电脑端即可。
若想**保留现有账号和配对**,把 Mac 上 `coding-server/data/users.json` 和 `data/tokens.json`
拷到 VPS 的 `data/` 下再启动(电脑端就不用重新配对)。

## ⚠️ 安全:上公网后建议加 TLS

现在是明文 `ws://` / `http://`,在内网无所谓,但**一上公网,登录 token 和图片就是明文在
互联网上传输**。建议套 TLS(`wss://` / `https://`),最省事的是用 Caddy 自动证书(需要一个域名):

```
# /etc/caddy/Caddyfile(把 your.domain.com 换成你的域名)
your.domain.com {
    reverse_proxy /ws*  localhost:8090
    reverse_proxy /api/* localhost:8080
}
```

> 注意:启用 TLS 后,iOS 和电脑端要改用 `wss://` / `https://` 连接 —— 这需要改客户端代码。
> 建议:**先用明文把链路跑通**,确认手机/电脑端都能连上、发图正常,再让 Claude 帮你上 TLS。

## 排查

- 连不上:先 `curl http://IP:8080/api/app/version`。不通 → 防火墙/安全组没放开;通 → 检查手机填的 IP/端口
- 起不来:`./run.sh log` 或 `journalctl -u coding-server -f` 看报错;多半是 Java 版本低于 17
- 端口占用:`sudo lsof -iTCP:8080 -sTCP:LISTEN`
