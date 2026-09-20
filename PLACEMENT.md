# 放置说明（如何上传到你的 fork 仓库 Wu140360/openwrt-ci-roc）

把本 zip 内 `zn-m2-config/` 目录中的内容**合并**到 fork 仓库根目录：

```
zn-m2-config/                <- 此目录内的内容，直接合并到仓库根
├── configs/                 -> 覆盖/新增到仓库 configs/
│   ├── ZN-M2.config
│   └── General.config
├── scripts/ZN-M2-script.sh  -> 放到仓库 scripts/
├── .github/workflows/       -> 放到仓库 .github/workflows/
│   ├── Build-OpenWrt.yml    （增强版，覆盖同名原文件）
│   └── ZN-M2.yml            （新增：兆能 M2 构建入口）
├── files/                   -> 覆盖层，随固件打包进 /etc 等
├── check-config.sh
├── validate.sh
├── final-check.sh
└── README-ZN-M2.md
```

## 快速开始
1. fork https://github.com/laipeng668/openwrt-ci-roc → Wu140360/openwrt-ci-roc
2. 把本 zip 内容**合并**进 fork 仓库根（同名覆盖，新增添加）
3. GitHub → Actions → 选 **ZN-M2** workflow → Run workflow
4. 构建完成后，固件在 Release `ZN-M2`：`*squashfs-sysupgrade.bin`

## 本地自检（在仓库根执行）
```bash
bash check-config.sh     # 符号冲突/重复/需求核对
bash validate.sh         # 完整性 + YAML/Bash 语法 + 引用
bash final-check.sh      # 端到端模拟合并 + 需求覆盖
```
