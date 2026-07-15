$url = "https://raw.githubusercontent.com/mhmtsk44/bilgisayar-araci/main/Bilgisayar_Araci_Ana.ps1"
$kod = (Invoke-RestMethod -Uri $url).Trim([char]0xFEFF)
Invoke-Expression $kod