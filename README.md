# xray-rp

`xray-rp.sh` 是一个用于在常见 Linux 发行版上自动安装和配置 Xray (VLESS + REALITY + Reverse v4) 的一键脚本。

## 一键安装

```bash
bash <(curl -fsSL https://github.com/kilvil/xray-rp/releases/latest/download/xray-rp.sh)
```

## 手动运行

如果你更喜欢手动执行，也可以先下载脚本再运行：

```bash
curl -fsSLO https://raw.githubusercontent.com/kilvil/xray-rp/main/xray-rp.sh
chmod +x xray-rp.sh
sudo ./xray-rp.sh
```

## 配置成功的输出：

```bash
是否配置本地 Socks5(127.0.0.1:10808) 并走 Portal:443 正向代理? [y/n] [y]: n
✔ 配置校验通过
● xray.service - Xray Service
     Loaded: loaded (/etc/systemd/system/xray.service; enabled; preset: enabled)
    Drop-In: /etc/systemd/system/xray.service.d
             └─10-donot_touch_single_conf.conf
     Active: active (running) since Mon 2025-10-20 07:55:10 UTC; 61ms ago
 Invocation: 2080ea6927b448d98f932fc1740f6955
       Docs: https://github.com/xtls
   Main PID: 2921 (xray)
      Tasks: 3 (limit: 2310)
     Memory: 2.8M (peak: 3M)
        CPU: 21ms
     CGroup: /system.slice/xray.service
             └─2921 /usr/local/bin/xray run -config /usr/local/etc/xray/config.json

Oct 20 07:55:10 ubuntu-xxxxxx2 systemd[1]: Started xray.service - Xray Service.
✔ Bridge 完成。现在：
  * 反向隧道入口：访问 http://15x.xxx.xxx.6:31234 会被转发到 Bridge 的 127.0.0.1:80
日志: tail -F /var/log/xray/error.log /var/log/xray/access.log
```

## 快速验证

Bridge机器上运行nginx服务，用于验证隧道打通：
```bash
sudo apt update
sudo apt install -y nginx
sudo systemctl enable --now nginx
sudo tee /var/www/html/index.html >/dev/null <<'HTML'
<!doctype html><meta charset="utf-8"><title>Nginx OK</title>
<h1>🎉 Hello from Nginx (80)</h1>
HTML
sudo nginx -t && sudo systemctl reload nginx
# 可选：放行防火墙
sudo ufw allow 80/tcp
# 验证
curl -I http://127.0.0.1
```

## 发布说明

每次向 `main` 分支推送都会触发 GitHub Actions，自动创建一个携带最新 `xray-rp.sh` 的 Release，方便直接下载或通过上述命令使用。
