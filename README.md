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

## 发布说明

每次向 `main` 分支推送都会触发 GitHub Actions，自动创建一个携带最新 `xray-rp.sh` 的 Release，方便直接下载或通过上述命令使用。
