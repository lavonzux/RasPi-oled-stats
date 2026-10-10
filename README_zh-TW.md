# RasPi-oled-stats

![License](https://img.shields.io/badge/license-MIT-blue.svg)

[English](README.md) | 中文版

在 Raspberry Pi 上驅動 **128×64 SSD1306 OLED 顯示器**的輕量系統監控工具。

即時顯示主機名稱、IP 位址、CPU / RAM 使用率進度條、磁碟用量、系統運行時間與網路連線狀態。

專為 [52Pi Mini Tower Kit](https://wiki.52pi.com)（UPS Plus EP-0136 + OLED S-0005）設計，但應可適用於任何透過 I2C 連接的 SSD1306 顯示器。


## 顯示畫面

```
┌────────────────────────────────┐
│ Host: raspberrypi    [E] [W]   │  ← 主機名稱 + 乙太網路/Wi-Fi 圖示
│ IP: 192.168.1.42               │
│ CPU [████████░░░░] 67%         │  ← 進度條
│ RAM [████░░░░░░░░] 31%         │  ← 進度條
│ Disk: 4.2G/29G  15%            │  ← 每 5 秒與 uptime 交替顯示
└────────────────────────────────┘
```

- **右上角圖示** — 兩個 12×12 px 圖示分別指示乙太網路與 Wi-Fi 的連線狀態。
- **底部行** — 每 5 秒在磁碟用量與系統 uptime 之間交替。
- **開機 / 關機畫面** — 啟動與優雅結束時各顯示一張 128×64 自訂點陣圖。

## 硬體需求

| 元件 | 說明 |
|------|------|
| 主板 | Raspberry Pi（任何支援 I2C 的型號） |
| 顯示器 | 128×64 SSD1306 OLED，I2C 介面 |
| 接線 | SCL / SDA 腳位（I2C 匯流排） |

> 已於 [52Pi S-0005](https://wiki.52pi.com) 0.96 吋 OLED 模組上測試通過。

## 快速安裝

```bash
git clone https://github.com/lavonzux/RasPi-oled-stats.git
cd RasPi-oled-stats
chmod +x setup.sh
./setup.sh
```

安裝腳本會自動完成以下步驟：

1. 執行環境預檢（作業系統、Python 版本、I2C 狀態、必要檔案）
2. 安裝系統套件（`python3-venv`、`python3-dev`、`i2c-tools`、`swig`、Pillow 編譯依賴等）
3. 透過 `raspi-config` 啟用 I2C（如可用）
4. 建立 Python 虛擬環境（`.venv`）
5. 安裝 Python 相依套件並驗證關鍵模組可匯入
6. 產生並安裝帶有正確路徑的 systemd 服務
7. 啟動服務

### 安裝選項

```bash
./setup.sh           # 安裝或升級（安裝套件前會詢問確認）
./setup.sh -y        # 安裝，跳過所有確認提示
./setup.sh --check   # 僅檢查環境，不做任何變更
./setup.sh --remove  # 解安裝服務與虛擬環境（保留原始碼）
```

## 手動安裝

如果你偏好一步一步來：

```bash
# 1. 系統相依套件
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip python3-dev i2c-tools \
    swig liblgpio-dev libopenjp2-7 libfreetype6-dev libjpeg-dev

# 2. 啟用 I2C（Raspberry Pi）
sudo raspi-config nonint do_i2c 0

# 3. 建立虛擬環境並安裝 Python 套件
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

# 4. 確認 I2C 裝置（應在 0x3C 看到裝置）
i2cdetect -y 1

# 5. 測試執行
.venv/bin/python oled-stats.py

# 6. 安裝 systemd 服務
sudo cp oled-stats.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable oled-stats
sudo systemctl start oled-stats
```

> **注意：** 倉庫中的 `oled-stats.service` 檔案包含佔位路徑。使用 `setup.sh` 時，服務檔會自動以你系統上的正確路徑產生。手動安裝時，請先編輯檔案中的路徑再複製。

## 服務管理

```bash
# 查看狀態
sudo systemctl status oled-stats

# 查看日誌
journalctl -u oled-stats -n 50

# 即時追蹤日誌
journalctl -u oled-stats -f

# 修改程式碼後重啟
sudo systemctl restart oled-stats

# 停止服務
sudo systemctl stop oled-stats
```

## 專案結構

```
RasPi-oled-stats/
├── oled-stats.py          # 主程式
├── requirements.txt       # Python 相依套件（4 個套件）
├── setup.sh               # 含環境預檢的安裝腳本
├── oled-stats.service     # systemd 單元檔（範本）
├── icon/
│   ├── bootup.bmp         # 開機畫面（128×64 px，1-bit BMP）
│   ├── shutdown.bmp       # 關機畫面（128×64 px，1-bit BMP）
│   ├── eth_up.bmp         # 乙太網路已連線（12×12 px，1-bit）
│   ├── eth_down.bmp       # 乙太網路已斷線
│   ├── wifi_up.bmp        # Wi-Fi 已連線
│   ├── wifi_down.bmp      # Wi-Fi 已斷線
│   └── batt_*.bmp         # 電池電量圖示（0–100%、充電中）
├── README.md
└── README_zh-TW.md
```

## 運作原理

### 網路狀態偵測

1. **乙太網路** — 讀取 `/sys/class/net/<iface>/operstate`，支援 `eth*`、`enp*`、`enx*`、`en0` 命名。
2. **Wi-Fi** — 透過 `iwgetid -r` 檢查是否已關聯 SSID。
3. **網際網路可達性** — 透過指定介面 ping `8.8.8.8`。
4. 偵測結果會**快取 10 秒**（`INET_CHECK_INTERVAL`），避免頻繁 ping。

### 優雅結束

腳本會處理 `SIGTERM` 與 `SIGINT` 訊號。結束時顯示關機點陣圖，然後回傳 exit code `0`，讓 systemd 的 `Restart=on-failure` 不會觸發自動重啟。服務設定了 `TimeoutStopSec=5` 與 `KillSignal=SIGTERM` 以確保乾淨關閉。

## 自訂設定

| 項目 | 位置 |
|------|------|
| 修改 I2C 位址 | `oled-stats.py` 中的 `I2C_ADDR`（預設 `0x3C`） |
| 修改 ping 間隔 | `INET_CHECK_INTERVAL` 變數 |
| 修改底部行切換速度 | `time.time() / 5` — 更改 `5` 這個數字 |
| 替換開機/關機畫面 | 替換 `icon/bootup.bmp` 和 `icon/shutdown.bmp`（128×64，1-bit BMP） |
| 替換狀態圖示 | 替換 `icon/` 目錄下的檔案（12×12，1-bit BMP） |
| 調整進度條粗細 | `draw_bar()` 的 `bar_height` 參數 |

## 相依套件

執行時所需的 Python 套件（由 `setup.sh` 自動安裝）：

- [psutil](https://pypi.org/project/psutil/) — 系統指標
- [Pillow](https://pypi.org/project/pillow/) — 影像繪製
- [adafruit-blinka](https://pypi.org/project/Adafruit-Blinka/) — CircuitPython 相容層
- [adafruit-circuitpython-ssd1306](https://pypi.org/project/adafruit-circuitpython-ssd1306/) — OLED 驅動程式

## 致謝

本專案以 [geeekpi/luma.examples](https://github.com/geeekpi/luma.examples)（[52Pi / GeeekPi](https://wiki.52pi.com) 提供的 OLED 範例程式）作為起點開發而成。感謝他們提供了良好的基礎！
