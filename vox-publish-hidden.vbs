' Lancador silencioso da tarefa \Claude\VoxPublish.
' -WindowStyle Hidden nao esconde o console do pwsh (o console e alocado antes
' de o PowerShell ler o parametro), entao a tarefa chama este shim: WScript.Shell
' com windowStyle 0 nao cria janela nenhuma. Mantem o token interativo do usuario,
' preservando o acesso ao Credential Manager usado pelos pulls https do git.
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "E:\vox"
rc = sh.Run("pwsh.exe -NoProfile -File ""E:\vox\vox-publish-windows.ps1"" -GateOnNewEpisodes", 0, True)
WScript.Quit rc
