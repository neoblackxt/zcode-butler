' anchor-probe-launch.vbs (v0.12.2): 拉起 UIA 几何探针(powershell,经 ShellExecute 逃 Job)
CreateObject("WScript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & Replace(WScript.ScriptFullName, "anchor-probe-launch.vbs", "anchor-probe-ui.ps1") & """", 0, False
