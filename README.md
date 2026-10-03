# codex-windows-update-guard — Public Candidate V0.1

**Evidence first. Recovery second. 宁可 BLOCK，也不误修。**

这是一个针对 **Windows Codex Desktop 特定更新故障** 的保守型 PowerShell 候选工具：官方新版已经 Stage，但当前用户仍注册旧版，最终 Register / 版本切换没有完成。

> **当前状态：R2 独立终审 = PASS WITH CONDITIONS；BLOCKERS = NONE。**  
> **B-01 = SOURCE-LEVEL CLOSED。**  
> 这只表示当前源码安全门已通过独立只读终审，允许公开候选源码；**不等于 R2 Apply 已验收，不等于生产可用，也不等于 GitHub Release 就绪。**

本项目不是 OpenAI 官方产品，也不保证修复 OpenAI 上游更新器；它不适用于“新版尚未下载”“安装包损坏”等一般安装问题。

## 审计时间线

- R1 修订自评：`PASS WITH CONDITIONS / candidate only`
- R1 独立终审：`BLOCK`，发现 B-01（其他同包族版本、非固定名称辅助进程可能在 early continue 前漏检）
- R2：仅对 B-01 做最小源码修订
- R2 独立终审：`PASS WITH CONDITIONS`，`BLOCKERS = NONE`
- R2 Apply / 生产可用 / GitHub Release：仍为 **EVIDENCE INSUFFICIENT**

## 当前验证范围

- 目标平台严格限定为 **Windows 10 x64 + 64 位 Windows PowerShell 5.1**。
- PowerShell 7、Windows 11、ARM64、Windows Server、32 位 PowerShell 均 BLOCK，不宣称已验证支持。
- R2 已完成静态源码审阅、Windows PowerShell 5.1 语法解析、R1→R2 diff 和独立终审。
- R2 尚未完成 Inspect/Apply 的独立运行验收。
- 旧本机恢复脚本曾真实成功恢复更新，但那不是本仓库 R2 Apply 的运行验收证据。

## 使用方式

应从 **Codex 之外的独立 Windows PowerShell 5.1 控制台**运行；不要 dot-source，也不要从 Codex 自己的进程树运行。

```powershell
# 默认 Inspect / Dry Run：不修改包或服务
powershell.exe -NoProfile -File .\Invoke-CodexWindowsUpdateGuard.ps1

# Apply 尚未完成独立运行验收，不建议把它当作生产恢复路径
powershell.exe -NoProfile -File .\Invoke-CodexWindowsUpdateGuard.ps1 -Apply
```

Apply 必须管理员。Inspect 不尝试提权，但当 AllUsers、会话或进程证据无法完整读取时会 BLOCK；非管理员 Inspect 因此可能无法完成。不要以其他管理员账号替代当前桌面用户。

## 结果与退出码

| 退出码 | VERDICT | SYSTEM_CHANGED | 含义 |
|---|---|---|---|
| 0 | PASS | NO | `NO_ACTION`：无可信较新 Staged 候选；或 `READY_DRY_RUN`：全部预检通过，但未执行恢复 |
| 0 | PASS | YES | `UPDATED`：已 Register，且目标身份、Manifest、最终服务身份与稳定状态/PID 终验通过；仍需人工正常启动 Codex 复核 |
| 10 | BLOCK | NO | 证据不足、平台/身份不支持、相关进程仍运行、并发或候选歧义；未发出包/服务修改调用 |
| 20 | FAIL | NO | 修改调用前发生未预期错误或明确验证失败 |
| 21 | FAIL | YES | 修改调用后失败，可能已有部分变化，应保持现场等待人工复核 |

控制台最后统一输出 `VERDICT`、`STATE`、`SYSTEM_CHANGED`、`CURRENT_VERSION`、`TARGET_VERSION`、`EXIT_CODE`，并附 `SERVICE_STATE`、`ERROR_CATEGORY`。不要把 Dry Run 的 PASS 解释为“升级已经完成”。

`SYSTEM_CHANGED=YES` 在发出 `Stop-Service` 或 Register 调用前一刻保守置位。该标志针对包/服务修改，不表示进程内 mutex、WTS/CLR 查询完全不产生操作系统运行痕迹。

## 关键防护

1. 通过 WTS 原生只读接口确认恰好一个活跃交互会话；额外断开会话也 BLOCK。桌面 SID、当前令牌 SID 与 SessionId 必须一致。
2. 当前包必须唯一，并校验 `OpenAI.Codex`、固定 package family、X64、Store、非开发模式、Ok、主包属性和规范安装目录。
3. AllUsers 使用 `PackageUserInformation.InstallState` 识别 Staged；较新候选必须同包族、同发行者并通过可信门；多个候选直接 BLOCK。
4. Manifest 只来自已验证包自身的 InstallLocation；校验文件、无不支持的重解析路径、XML Identity 与 SHA256；XML 禁用 DTD/外部解析器。
5. 检查当前包、目标包、其他同包族版本以及当前用户 AppData Codex Host。R2 在 early continue 前识别同包族 WindowsApps 路径，使非固定名称的辅助进程也无法沿 B-01 旧路径漏检。
6. 服务必须精确匹配固定名称、当前可信包固定二进制、LocalSystem、Auto/Manual；Running 时继续核验 PID、路径、Owner 和创建时间。
7. Apply 前完整重做预检并核对快照；服务停止必须确认 `Stopped + PID=0 + 原 PID 消失` 后才允许 Register。
8. Register 前再次核对用户、当前包、唯一 Staged 候选、目标服务布局、Manifest 哈希、相关进程与服务状态。
9. UPDATED/PASS 前重新核验目标包、Manifest 与最终服务身份/稳定状态；证据不完整则 FAIL/21/YES。
10. Global Named Mutex 仅防本工具自身并发；它不能锁住 Store 更新器、SCM 或用户启动进程，因此实现仍采取重复核对和 fail-closed。

## 已知限制

- `StartMode=Disabled` 当前仍保守 BLOCK。这是已知可用性限制，不是已证实的安全漏洞。
- 同包族辅助进程识别使用固定 WindowsApps 路径模式；路径字符串相似可能造成保守误阻断，但不会因此授权写入或信任该目录。
- 查询服务 / 进程 / Owner 与后续写操作不是 Windows 事务，仍存在外部竞态窗口。
- 15 秒服务停止轮询不是所有 RPC/CIM 调用的硬实时上限。
- 未知名称且 EXE 路径不可读的进程、未来 Host 布局变化，不在“全部覆盖”保证内。

## 仍为 EVIDENCE INSUFFICIENT

- `READY_DRY_RUN`
- R2 Inspect
- R1 / R2 Apply
- R2 `Stop → Register → 最终服务终验`
- R2 Register 失败真实运行路径
- B-01 动态场景真实运行验证
- Windows 11、ARM64
- 多用户 / Fast User Switching
- 公共生产可用性
- GitHub Release 就绪

## 失败与恢复策略

本候选不自动 `Start-Service`，也不自动卸载回滚或强杀 Codex/ChatGPT。若修改已发出后失败，则保持 `FAIL / 21 / YES`，保留现场供人工复核。不要盲目重复执行 Apply。

## 日志与隐私

脚本只向控制台输出最小 JSON 与固定结果行，不使用 Transcript、不创建日志文件、不上传。不会输出用户名、机器名、SID、完整个人目录、命令行、凭据或原始异常文本。

Inspect 不持久修改包、服务或设置；但 Windows PowerShell 5.1 的 `Add-Type` 编译器可能使用系统临时文件，因此不要宣传为“操作系统层面绝对零文件活动”。

## 不做的事情

不强杀 Codex/ChatGPT，不下载包，不删除/卸载包，不清用户数据，不禁用服务，不接管 WindowsApps 权限，不修改 PATH 或全局 ExecutionPolicy，不提供 GUI、后台常驻、多用户更新或自动上传。

## 完整性

发布包提供 `SHA256SUMS.txt`。当前脚本 SHA256：

`98354E1470C72AB4DD893505017711251CC40B1B97ABDDC428F6A61B2A82AB29`

## License

MIT License。详见 [`LICENSE`](LICENSE)。
