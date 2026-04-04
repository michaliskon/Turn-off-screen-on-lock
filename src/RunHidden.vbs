' RunHidden.vbs — Launches the controller with a truly hidden window.
' Usage: wscript.exe RunHidden.vbs <Action>
'
' Resolves the controller path from its own folder so the scheduled
' tasks do not need to embed absolute paths in the VBS arguments.

If WScript.Arguments.Count = 0 Then WScript.Quit 1

Dim fso, scriptDir, action, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

' RISK-008: Verify the controller script exists alongside this launcher.
' If missing (e.g., folder was deleted and recreated by an attacker), exit
' immediately to prevent binary planting attacks.
If Not fso.FileExists(scriptDir & "\LockTimeoutController.ps1") Then WScript.Quit 2

action = WScript.Arguments(0)

' Whitelist valid actions to prevent command injection.
' Must match the ValidateSet in LockTimeoutController.ps1.
Select Case LCase(action)
    Case "onlock", "onunlock", "promoteonwake"
        ' Valid action
    Case Else
        WScript.Quit 1
End Select

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\LockTimeoutController.ps1"" -Action """ & action & """"

CreateObject("WScript.Shell").Run cmd, 0, False
