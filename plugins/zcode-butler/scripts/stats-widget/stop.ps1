$host.ui.RawUI.WindowTitle = 'stats-widget-stop'
# v0.2.1:与 widget/stop.ps1 同机制(旧版窗口枚举式废弃 —— 只覆盖「窗口活着」状态,
# 启动早期未建窗/窗口已毁进程未退时假阴性报 not running;详见开发日志 v0.2.1)
. (Join-Path $PSScriptRoot '..\lib\widget-common.ps1')
Stop-ButlerInstance -Kind 'stats' -ProcessMatch 'stats-widget\.ps1'
# v0.12:连带清掉 CDP 探锚(node),避免孤儿探针继续写锚文件
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*anchor-probe.mjs*' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
# v0.12.5:连带清 UIA 探锚(powershell 版,现行主用;老探针持独占锁会挡住新代拉起)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*anchor-probe-ui*' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
# v0.13:连带清 metrics 采集器(node)
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*stats-widget*metrics.mjs*' } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
