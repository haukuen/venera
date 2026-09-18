## 注意

这是自用项目，可能会随时做激进更改，使用请慎重。

如果你从[原项目](https://github.com/venera-app/venera)迁移过来，**WebDAV 同步目录请使用新的目录，不要和原项目共用同一目录**，否则可能导致数据异常。

## 安装

### 从 Release 下载

从 [GitHub Releases](https://github.com/haukuen/venera/releases) 下载最新版本。

### 包管理器下载

**Windows (Scoop)**

```bash
scoop bucket add endless https://github.com/haukuen/endless
scoop install venera
```

**macOS (Homebrew)**

```bash
brew tap haukuen/tap
brew install --cask venera
```

## 命令行

桌面版可通过 `venera --headless` 调用已安装的漫画源，执行搜索、元数据查询、分类、排行、探索及远程收藏管理。详细命令、JSON 协议和安全边界见 [Headless Mode](doc/headless_doc.md)。
