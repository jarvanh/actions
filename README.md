# GitHub Actions

个人自动化工作流集合，由 GitHub Actions 定时/事件触发。

## 目录结构

```
.
├── .github/
│   ├── scripts/                # 各工作流配套脚本（按领域分组）
│   │   ├── openlist/           # OpenList 同步引擎（load_all.sh 统一加载）
│   │   │   └── tests/          # 逻辑验证测试（mock 外部依赖，本地可跑）
│   │   ├── proxy-speedtest/    # 代理测速
│   │   └── telegram/           # Telegram 视频流水线（下载→去重→转码→上传→通知）
│   └── workflows/              # GitHub Actions 工作流定义
├── .gitignore
└── README.md
```

## 脚本模块说明

| 模块 | 用途 | 关联工作流 |
|------|------|-----------|
| `openlist/` | OpenList 挂载同步、缺失修复、任务编排 | `openlist.yml` |
| `openlist/tests/` | `sync.sh` truth-check 逻辑验证 | 本地运行: `bash .github/scripts/openlist/tests/test_truth.sh` |
| `proxy-speedtest/` | 代理节点测速 | `proxy-speedtest*.yml` |
| `telegram/` | yt-dlp 下载后处理、去重、转码上传 TG 频道、通知 | `ph-dl.yml`、`upload-video-to-tg.yml` |

## 约定

- 新脚本放入对应领域子目录；无匹配子目录时新建，避免平铺在 `scripts/` 根下
- `openlist/*.sh` 会被工作流整体 `cp` 到 `/tmp` 执行，测试等非库文件放 `tests/` 子目录
- 脚本间相互引用统一使用 `${GITHUB_WORKSPACE}/.github/scripts/<模块>/` 绝对路径
