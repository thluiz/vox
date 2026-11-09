' Lancador silencioso da tarefa \Claude\VoxPrivatePublish (mesmo motivo do vox-publish-hidden.vbs:
' o console do pwsh e alocado antes de o PowerShell ler -WindowStyle Hidden, entao a tarefa chama
' este shim; WScript.Shell com windowStyle 0 nao cria janela. Mantem o token interativo do usuario,
' que o git usa para o Credential Manager nos pulls https.
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "E:\vox"
rc = sh.Run("pwsh.exe -NoProfile -File ""E:\vox\vox-publish-private.ps1"" -GateOnNewEpisodes", 0, True)
WScript.Quit rc
