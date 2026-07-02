 <#
    Uygulama İndirme-Güncelleme-Sürücü Yedek Alma-Temizleme Aracı
    Hazırlayan: Mehmet IŞIK
    Güncelleme: 03.07.2026
    Kullanım: Sağ tık -> "PowerShell ile çalıştır" veya yönetici PowerShell'de:
              powershell -ExecutionPolicy RemoteSigned -File "Bilgisayar_Araci.ps1"
    NOT: Dosyayı "UTF-8 with BOM" olarak kaydedin (Türkçe + çerçeve karakterleri için).
#>
# ===================== IRM|IEX İLE ÇALIŞTIRILDIYSA KENDİNİ TEMP'E KAYDET =====================
# Betik diskte bir dosya olarak DEĞİL de (irm|iex ile) bellekte çalıştırıldıysa,
# $PSCommandPath ve $MyInvocation.MyCommand.Path BOŞ olur.
# Bu durumda betiğin tamamını Temp'e .ps1 olarak indirip oradan yeniden başlatırız.

$CalisanDosya = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($CalisanDosya)) { $CalisanDosya = $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($CalisanDosya)) {
    # --- Betik DİSKTE DEĞİL (irm|iex modu) -> Temp'e kaydet ve oradan çalıştır ---
    $ScriptUrl  = "https://raw.githubusercontent.com/mhmtsk44/bilgisayar-araci/refs/heads/main/Bilgisayar_Araci.ps1"
    $HedefDosya = Join-Path $env:TEMP "Bilgisayar_Araci.ps1"

    # ===== ÖNCE ESKİSİNİ SİL (her seferinde güncel sürüm için) =====
    if (Test-Path $HedefDosya) {
        Write-Host "Eski surum bulundu, siliniyor..." -ForegroundColor Yellow
        Write-Host "  Silinen: $HedefDosya" -ForegroundColor DarkGray
        try {
            Remove-Item -Path $HedefDosya -Force -ErrorAction Stop
        } catch {
            Write-Host "UYARI: Eski dosya silinemedi (kilitli olabilir): $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    # ===== /ÖNCE ESKİSİNİ SİL =====

    Write-Host "Betik Temp klasorune indiriliyor..." -ForegroundColor Yellow
    Write-Host "  Hedef: $HedefDosya" -ForegroundColor DarkGray

    $indi = $false
    try {
        $eskiPP = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $HedefDosya -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        $ProgressPreference = $eskiPP
        $indi = (Test-Path $HedefDosya) -and ((Get-Item $HedefDosya).Length -gt 0)
    } catch {
        $indi = $false
    }

    if ($indi) {
        Write-Host "Guncel surum indirildi. Temp'teki dosyadan yeniden baslatiliyor..." -ForegroundColor Green
        # -NoExit: hata olsa bile pencere kapanmasın; -File: yol boşluk içerse bile güvenli
        Start-Process powershell -ArgumentList @(
            "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$HedefDosya`""
        )
        # Bellekteki (irm|iex) kopya işini bitirdi; kapan.
        return
    } else {
        Write-Host "HATA: Betik Temp'e indirilemedi. Internet baglantisini kontrol edin." -ForegroundColor Red
        Write-Host "Yine de bellekten devam ediliyor..." -ForegroundColor DarkYellow
        # İndirilemezse: eski davranış (bellekten devam) korunur.
    }
}
# ===================== /TEMP'E KAYDET =====================
# ===================== YÖNETİCİ KONTROLÜ + TEK PENCERE BAŞLATMA =====================

function Test-Admin {
    $kimlik = [Security.Principal.WindowsIdentity]::GetCurrent()
    $rol = New-Object Security.Principal.WindowsPrincipal($kimlik)
    return $rol.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ===================== WINGET KURULUM/KONTROL (LTSC uyumlu, takılmaz) =====================
function Install-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    Write-Host "Winget bulunamadi, kuruluyor..." -ForegroundColor Yellow

    # --- Zaman asimli calistirma yardimcisi (job ile, asla sonsuz takilmaz) ---
    function Invoke-ZamanAsimli {
        param([scriptblock]$Kod, [int]$Saniye = 120)
        $job = Start-Job -ScriptBlock $Kod
        if (Wait-Job $job -Timeout $Saniye) {
            Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            return $true
        } else {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            return $false
        }
    }

    # ============================================================
    # YOL 1: PSGallery scripti (winget-install) - LTSC'de en basarili
    # ============================================================
    Write-Host "  [Yol 1] PSGallery 'winget-install' scripti deneniyor..." -ForegroundColor DarkGray
    try {
        $psg = Invoke-ZamanAsimli -Saniye 180 -Kod {
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Script -Name winget-install -Force -Scope CurrentUser -ErrorAction Stop
            $p = (Get-InstalledScript winget-install -ErrorAction Stop).InstalledLocation
            & (Join-Path $p "winget-install.ps1") -Force
        }
        Start-Sleep -Seconds 3
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "Winget basariyla kuruldu (Yol 1)." -ForegroundColor Green
            return $true
        } else {
            Write-Host "        Yol 1 sonuc vermedi, Yol 2 deneniyor..." -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "        Yol 1 basarisiz, Yol 2 deneniyor..." -ForegroundColor DarkYellow
    }

    # ============================================================
    # YOL 2: Manuel (VCLibs + UI.Xaml + App Installer) - zaman asimli
    # ============================================================
    Write-Host "  [Yol 2] Manuel bagimlilik kurulumu deneniyor..." -ForegroundColor DarkGray
    $mimari = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $tmp = $env:TEMP

    function Indir-Dosya {
        param([string]$Url, [string]$Hedef, [int]$Timeout = 60)
        try {
            $eski = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $Hedef -UseBasicParsing -TimeoutSec $Timeout -ErrorAction Stop
            $ProgressPreference = $eski
            return $true
        } catch { return $false }
    }

    # Sideload politikasi
    try {
        $sk = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"
        if (-not (Test-Path $sk)) { New-Item -Path $sk -Force | Out-Null }
        New-ItemProperty -Path $sk -Name "AllowAllTrustedApps" -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    # VCLibs
    Write-Host "        VCLibs..." -ForegroundColor DarkGray
    $vclibs = Join-Path $tmp "vclibs_$mimari.appx"
    if (Indir-Dosya "https://aka.ms/Microsoft.VCLibs.$mimari.14.00.Desktop.appx" $vclibs 60) {
        try { Add-AppxPackage -Path $vclibs -ErrorAction SilentlyContinue } catch {}
    }

    # UI.Xaml
    if (-not (Get-AppxPackage -Name "Microsoft.UI.Xaml.2.8*" -ErrorAction SilentlyContinue)) {
        Write-Host "        UI.Xaml..." -ForegroundColor DarkGray
        $nupkg = Join-Path $tmp "uixaml.zip"; $xamlDir = Join-Path $tmp "uixaml_extract"
        if (Indir-Dosya "https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.8.6" $nupkg 60) {
            try {
                if (Test-Path $xamlDir) { Remove-Item $xamlDir -Recurse -Force -ErrorAction SilentlyContinue }
                Expand-Archive -Path $nupkg -DestinationPath $xamlDir -Force -ErrorAction Stop
                $xa = Get-ChildItem -Path $xamlDir -Recurse -Filter "*.appx" -ErrorAction SilentlyContinue |
                      Where-Object { $_.FullName -match "\\$mimari\\" } | Select-Object -First 1
                if ($xa) { Add-AppxPackage -Path $xa.FullName -ErrorAction SilentlyContinue }
            } catch {}
        }
    }

    # App Installer (zaman asimli kurulum - KRITIK)
    Write-Host "        App Installer indiriliyor..." -ForegroundColor DarkGray
    $appinst = Join-Path $tmp "appinst.msixbundle"
    $license = Join-Path $tmp "license.xml"
    $lisansli = $false
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest" `
               -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        $msix = $rel.assets | Where-Object { $_.name -like "*.msixbundle" } | Select-Object -First 1
        $lic  = $rel.assets | Where-Object { $_.name -like "*License1.xml" } | Select-Object -First 1
        if ($msix -and $lic) {
            $ok1 = Indir-Dosya $msix.browser_download_url $appinst 120
            $ok2 = Indir-Dosya $lic.browser_download_url  $license 60
            if ($ok1 -and $ok2) {
                Write-Host "        Kuruluyor (en fazla 120 sn, takilirsa atlanir)..." -ForegroundColor DarkGray
                $ap = $appinst; $lp = $license
                $lisansli = Invoke-ZamanAsimli -Saniye 120 -Kod {
                    Add-AppxProvisionedPackage -Online -PackagePath $using:ap -LicensePath $using:lp -ErrorAction Stop | Out-Null
                }
            }
        }
    } catch {}

    if (-not $lisansli) {
        if (Indir-Dosya "https://aka.ms/getwinget" $appinst 120) {
            $ap2 = $appinst
            Invoke-ZamanAsimli -Saniye 120 -Kod {
                Add-AppxPackage -Path $using:ap2 -ErrorAction SilentlyContinue
            } | Out-Null
        }
    }

    # --- Dogrulama ---
    Start-Sleep -Seconds 3
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Winget basariyla kuruldu (Yol 2)." -ForegroundColor Green
        return $true
    }

    # ============================================================
    # Hicbiri olmadi - TAKILMADAN, net mesajla cik
    # ============================================================
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor DarkYellow
    Write-Host "  Winget bu bilgisayara otomatik kurulamadi (LTSC kisitlamasi)." -ForegroundColor Yellow
    Write-Host "  Bilgisayari yeniden baslatip tekrar deneyin, veya program" -ForegroundColor DarkYellow
    Write-Host "  winget'siz devam etsin (bazi islemler yine calisir)." -ForegroundColor DarkYellow
    Write-Host "  ============================================================" -ForegroundColor DarkYellow
    return $false
}
# Betiğin indirileceği adres (yalnızca yerel dosya yoksa yedek olarak kullanılır)
$ScriptUrl = "https://raw.githubusercontent.com/mhmtsk44/bilgisayar-araci/refs/heads/main/Bilgisayar_Araci.ps1"

# Çalışan betiğin tam yolu (yönetici/terminal yükseltmesinde AYNI dosya yeniden çalışır)
$BetikYolu = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($BetikYolu)) { $BetikYolu = $MyInvocation.MyCommand.Path }

# Yükseltme komutunu üret: yerel dosya varsa onu çalıştır, yoksa indir
function Get-BaslatmaKomutu {
    if (-not [string]::IsNullOrWhiteSpace($BetikYolu) -and (Test-Path $BetikYolu)) {
        # GÜVENLİ: incelenen yerel dosyanın kendisi çalışır, offline da çalışır
        return @{ Tip = "Dosya"; Deger = $BetikYolu }
    } else {
        # YEDEK: yerel dosya yoksa (örn. irm ile çağrıldıysa) uzaktan indir
        return @{ Tip = "Komut"; Deger = "irm '$ScriptUrl' | iex" }
    }
}

# AŞAMA 1: Yönetici değilsek -> yönetici olarak yeniden başlat
if (-not (Test-Admin)) {
    Write-Host "Yönetici izniyle yeniden başlatılıyor..." -ForegroundColor Yellow
    $bk = Get-BaslatmaKomutu
    try {
        if ($bk.Tip -eq "Dosya") {
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$($bk.Deger)`"" -Verb RunAs -ErrorAction Stop
        } else {
            # UZAKTAN (irm|iex) MOD: -NoExit eklendi ki hata olsa da pencere kapanmasın
            Start-Process powershell -ArgumentList "-NoExit -ExecutionPolicy Bypass -Command `"$($bk.Deger)`"" -Verb RunAs -ErrorAction Stop
        }
    } catch {
        Write-Host ""
        Write-Host "HATA: Yönetici izni verilmedi veya yükseltme başarısız oldu." -ForegroundColor Red
        Write-Host "Ayrıntı: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-Host ""
        Read-Host "Kapatmak için Enter'a basın"
    }
    exit
}

# AŞAMA 1.5: Winget'i garantiye al
$WingetVar = Install-Winget

# ===================== AŞAMA 2: WINDOWS TERMINAL'DE AÇ (güvenli, döngüsüz) =====================
if ((-not $env:WT_SESSION) -and ($env:BILGISAYAR_ARACI_WT -ne "1")) {

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (-not $wt) {
        $wtPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
        if (Test-Path $wtPath) { $wt = $wtPath }
    }

    if ($wt) {
        $bk = Get-BaslatmaKomutu
        try {
            if ($bk.Tip -eq "Dosya") {
                # Döngü bayrağını ÖNCEDEN bu pencerede ayarla; yeni pencere miras alır
                [Environment]::SetEnvironmentVariable("BILGISAYAR_ARACI_WT", "1", "Process")
                # -File ile çalıştır: yol boşluk içerse bile güvenli
                Start-Process wt.exe -ArgumentList @(
                    "powershell", "-NoExit", "-ExecutionPolicy", "Bypass",
                    "-File", "`"$($bk.Deger)`""
                ) -ErrorAction Stop
            } else {
                Start-Process wt.exe -ArgumentList @(
                    "powershell", "-NoExit", "-ExecutionPolicy", "Bypass",
                    "-Command", "`"$($bk.Deger)`""
                ) -ErrorAction Stop
            }
            exit   # wt açıldı -> başlatıcı pencereyi kapat
        } catch {
            # wt açılamadı -> bu pencerede devam et
        }
    }
}

# ===================== TEMEL AYARLAR =====================
$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Bilgisayar Aracı - Mehmet IŞIK"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if ($Host.Name -eq 'ConsoleHost') {
    try {
        $raw = $Host.UI.RawUI
        $max = $raw.MaxPhysicalWindowSize
        $genislik = [math]::Min(120, $max.Width)
        $yukseklik = [math]::Min(46, $max.Height)
        $raw.BufferSize = New-Object Management.Automation.Host.Size($genislik, 3000)
        $raw.WindowSize = New-Object Management.Automation.Host.Size($genislik, $yukseklik)
    } catch {}
}

try { $Host.UI.RawUI.BackgroundColor = "Black"; $Host.UI.RawUI.ForegroundColor = "Gray"; Clear-Host } catch {}

# ===================== MODERN TEMA / RENK PALETİ =====================
$Tema = @{
    Cerceve  = "DarkCyan"
    Vurgu    = "Cyan"
    Metin    = "Gray"
    Baslik   = "White"
    Basari   = "Green"
    Hata     = "Red"
    Soluk    = "DarkGray"
}
# ===================== MODERN ÇERÇEVE =====================
$BoxWidth = 78
function Show-Top    { Write-Host ("╔" + ("═" * $BoxWidth) + "╗") -ForegroundColor $Tema.Cerceve }
function Show-Bottom { Write-Host ("╚" + ("═" * $BoxWidth) + "╝") -ForegroundColor $Tema.Cerceve }
function Show-Divider{ Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve }
function Show-Bos    { Write-Host ("║" + (" " * $BoxWidth) + "║") -ForegroundColor $Tema.Cerceve }
function Show-Line {
    param([string]$Metin, [string]$Renk = $Tema.Metin)
    $temiz = $Metin
    if ($temiz.Length -gt $BoxWidth) { $temiz = $temiz.Substring(0, $BoxWidth) }
    $bosluk = [math]::Max(1, $BoxWidth - $temiz.Length)
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host (" " + $temiz + (" " * ($bosluk - 1))) -ForegroundColor $Renk -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve
}

function Show-Header {
    param([string]$Baslik)
    Clear-Host
    Show-Top
    Show-Line "  ▙▖ BİLGİSAYAR ARACI" $Tema.Soluk
    Show-Line ("  " + $Baslik) $Tema.Vurgu
    Show-Bottom
    Write-Host ""
}

function Write-Result {
    param(
        $Basari,
        $Mesaj = ""
    )

    # --- AKILLI PARAMETRE ALGILAMA (iki çağrı stilini de destekler) ---
    #   DOĞRU:  Write-Result $true "mesaj"      (bool, string)
    #   ESKİ:   Write-Result $true "mesaj"       (string, bool)  ← otomatik düzeltilir
    # Eğer $Basari bool DEĞİL ama $Mesaj bool ise, parametreler ters gelmiştir → yer değiştir.
    if (($Basari -isnot [bool]) -and ($Mesaj -is [bool])) {
        $gecici = $Basari
        $Basari = $Mesaj
        $Mesaj  = $gecici
    }

    # --- Basari değerini güvenli şekilde Boolean'a çevir ---
    $durum = $false
    try {
        if ($Basari -is [bool]) {
            $durum = $Basari
        } elseif ($Basari -is [int] -or $Basari -is [long]) {
            $durum = ([int]$Basari -eq 1)
        } else {
            $metin = "$Basari".Trim().ToLower()
            $durum = ($metin -eq 'true' -or $metin -eq '1')
        }
    } catch {
        $durum = $false
    }

    # $Mesaj'ı her zaman metne çevir (bool geldiyse bile güvenli)
    $mesajMetni = "$Mesaj"

    if ($durum) {
        Write-Host "  ✓  $mesajMetni" -ForegroundColor $Tema.Basari
    } else {
        Write-Host "  ✗  $mesajMetni" -ForegroundColor $Tema.Hata
    }
}
function Confirm-Islem {
    param([string]$Soru = "Bu işlemi yapmak istediğinize emin misiniz?")
    Write-Host ""
    $cevap = Read-Host "  $Soru (E/H)"
    return ($cevap -eq "E" -or $cevap -eq "e")
}

# ===================== WINGET BİLGİLENDİRME EKRANI =====================
function Show-WingetHelp {
    Show-Header "WINGET (PAKET YÖNETİCİSİ) BULUNAMADI"

    Write-Host "  Bilgisayarınızda Winget yüklü değil." -ForegroundColor $Tema.Hata
    Write-Host ""
    Write-Host "  Winget, Windows 10 (1809+) ve Windows 11'de varsayılan" -ForegroundColor $Tema.Metin
    Write-Host "  olarak gelen resmi bir paket yöneticisidir. Yüklü değilse" -ForegroundColor $Tema.Metin
    Write-Host "  aşağıdaki yöntemlerden biriyle kurabilirsiniz." -ForegroundColor $Tema.Metin
    Write-Host ("  " + ("-" * 74)) -ForegroundColor $Tema.Cerceve

    Write-Host "  YÖNTEM 1 — Microsoft Store (Önerilen)" -ForegroundColor $Tema.Vurgu
    Write-Host "   1) Başlat menüsünden 'Microsoft Store' uygulamasını açın." -ForegroundColor $Tema.Metin
    Write-Host "   2) Arama çubuğuna 'Uygulama Yükleyici' yazın." -ForegroundColor $Tema.Metin
    Write-Host "      (İngilizce: 'App Installer')" -ForegroundColor $Tema.Soluk
    Write-Host "   3) 'Uygulama Yükleyici'yi bulun ve Yükle/Güncelle deyin." -ForegroundColor $Tema.Metin
    Write-Host "   4) Kurulum bitince winget kullanıma hazır olur." -ForegroundColor $Tema.Metin
    Write-Host ""

    Write-Host "  YÖNTEM 2 — Geliştirici Modu üzerinden" -ForegroundColor $Tema.Vurgu
    Write-Host "   1) Başlat > 'Ayarlar' uygulamasını açın." -ForegroundColor $Tema.Metin
    Write-Host "   2) 'Gizlilik ve Güvenlik' > 'Geliştiriciler için' bölümüne gidin." -ForegroundColor $Tema.Metin
    Write-Host "      (Win 10: 'Güncelleme ve Güvenlik' > 'Geliştiriciler için')" -ForegroundColor $Tema.Soluk
    Write-Host "   3) 'Geliştirici Modu'nu açın." -ForegroundColor $Tema.Metin
    Write-Host "   4) Ardından Store'dan 'Uygulama Yükleyici'yi kurun." -ForegroundColor $Tema.Metin
    Write-Host ""

    Write-Host "  YÖNTEM 3 — Otomatik kurulum (bu araç)" -ForegroundColor $Tema.Vurgu
    Write-Host "   Bu araç açılışta winget'i otomatik kurmayı dener." -ForegroundColor $Tema.Metin
    Write-Host "   Başarısız olduysa internet bağlantınızı kontrol edip" -ForegroundColor $Tema.Metin
    Write-Host "   programı yeniden başlatın." -ForegroundColor $Tema.Metin
    Write-Host ""

    # Kullanıcıyı doğrudan Store'a yönlendirme seçeneği
    $ac = Read-Host "  Microsoft Store'da 'Uygulama Yükleyici' sayfasını açmak ister misiniz? (E/H)"
    if ($ac -eq "E" -or $ac -eq "e") {
        try {
            Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1" -ErrorAction Stop
            Write-Result $true "Microsoft Store açıldı (Uygulama Yükleyici sayfası)."
        } catch {
            try {
                Start-Process "ms-windows-store://search/?query=Uygulama Yükleyici" -ErrorAction Stop
                Write-Result $true "Microsoft Store arama sayfası açıldı."
            } catch {
                Write-Result $false "Microsoft Store açılamadı: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Result $true "Store açılmadı. Winget'i daha sonra kurabilirsiniz."
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

# ===================== WINGET KAYNAK GÜNCELLEME =====================
if ($WingetVar) {
    winget source update 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Uyari: winget kaynak guncellemesi tamamlanamadi." -ForegroundColor DarkYellow
    }
}

# ===================== YARDIMCI FONKSİYONLAR =====================
function Get-FolderSizeMB {
    param([string]$Yol)
    if (-not (Test-Path $Yol)) { return 0 }
    try {
        $dosyalar = Get-ChildItem -Path $Yol -Recurse -Force -File -ErrorAction SilentlyContinue
        if (-not $dosyalar) { return 0 }
        $olcum = $dosyalar | Measure-Object -Property Length -Sum
        if (-not $olcum.Sum) { return 0 }
        return [math]::Round($olcum.Sum / 1MB, 2)
    } catch { return 0 }
}

function Get-FreeSpaceMB {
    param([string]$SurucuHarfi = "C")
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${SurucuHarfi}:'"
        if ($disk) { return [math]::Round($disk.FreeSpace / 1MB, 2) }
        return 0
    } catch { return 0 }
}

function Select-Folder {
    param([string]$Aciklama = "Klasör seçin")
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Aciklama
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

function Select-File {
    param([string]$Filtre = "JSON Dosyası (*.json)|*.json|Tüm Dosyalar (*.*)|*.*")
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = $Filtre
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}
function Invoke-YuzdeliIslem {
    param(
        [string]$Dosya,
        [string]$Argumanlar,
        [switch]$NullTemizle
    )

    $log = Join-Path $env:TEMP ("islem_" + [guid]::NewGuid().ToString("N") + ".log")
    "" | Out-File -FilePath $log -Encoding UTF8

    $islem = Start-Process -FilePath $Dosya `
             -ArgumentList $Argumanlar `
             -NoNewWindow -PassThru `
             -RedirectStandardOutput $log `
             -RedirectStandardError  ($log + ".err")

    $baslangic = Get-Date
    $sonYuzde  = 0
    $spinner   = @('|','/','-','\')
    $i = 0

    while (-not $islem.HasExited) {
        $yuzde = $sonYuzde
        try {
            if ($NullTemizle) {
                $ham = Get-Content $log -Raw -ErrorAction SilentlyContinue
                if ($ham) { $ham = $ham -replace "`0", "" }
            } else {
                $ham = (Get-Content $log -Tail 5 -ErrorAction SilentlyContinue) -join " "
            }

            if ($ham) {
                $m = [regex]::Matches($ham, '(\d{1,3})[.,]?\d*\s*%')
                if ($m.Count -gt 0) {
                    $son = $m[$m.Count - 1].Groups[1].Value
                    [int]$deger = 0
                    if ([int]::TryParse($son, [ref]$deger)) {
                        if ($deger -ge 0 -and $deger -le 100) { $yuzde = $deger }
                    }
                }
            }
        } catch {}
        if ($yuzde -lt $sonYuzde) { $yuzde = $sonYuzde }
        $sonYuzde = $yuzde

        $gecen = (Get-Date) - $baslangic
        $sure  = "{0:mm\:ss}" -f $gecen
        $kare  = $spinner[$i % $spinner.Count]

        $dolu  = [math]::Round($yuzde / 100 * 30)
        $cubuk = ("█" * $dolu) + ("░" * (30 - $dolu))

        Write-Host ("`r  [$kare] $cubuk  %$yuzde  •  $sure   ") -ForegroundColor Yellow -NoNewline
        Start-Sleep -Milliseconds 300
        $i++
    }

    # ===== KRİTİK DÜZELTME: İşlemin tam kapanmasını bekle =====
    $islem.WaitForExit()

    $cubukTam = "█" * 30
    Write-Host ("`r  [✓] $cubukTam  %100  •  tamamlandı        ") -ForegroundColor Green

    # ExitCode'u güvenli şekilde al (bazen -PassThru nesnesi geç dolar)
    $kod = $null
    try { $kod = $islem.ExitCode } catch { }
    if ($null -eq $kod) {
        # Yedek: process ID üzerinden tekrar dene
        try { $kod = (Get-Process -Id $islem.Id -ErrorAction SilentlyContinue).ExitCode } catch { }
    }
    if ($null -eq $kod) { $kod = 0 }  # okunamadıysa başarı say (işlem zaten bitti)

    Remove-Item $log, ($log + ".err") -Force -ErrorAction SilentlyContinue

    # SADECE sayıyı döndür (Write-Host çıktısı karışmasın diye)
    return [int]$kod
}
# ===================== UYGULAMA LİSTESİ (dizi — sıra %100 korunur) =====================

$Uygulamalar = @(
    @{ No = 1;  Ad = "Google Chrome";            Id = "Google.Chrome" }
    @{ No = 2;  Ad = "WinRAR";                    Id = "RARLab.WinRAR" }
    @{ No = 3;  Ad = "ACS Unified PC/SC Driver";  Id = "ACS.UnifiedPCSCDriver" }
    @{ No = 4;  Ad = "Adobe Reader";              Id = "Adobe.Acrobat.Reader.64-bit" }
    @{ No = 5;  Ad = "Internet Download Manager"; Id = "Tonec.InternetDownloadManager" }
    @{ No = 6;  Ad = "Mozilla Firefox";           Id = "Mozilla.Firefox" }
    @{ No = 7;  Ad = "VLC Media Player";          Id = "VideoLAN.VLC" }
    @{ No = 8;  Ad = "Notepad++";                 Id = "Notepad++.Notepad++" }
    @{ No = 9;  Ad = "Visual Studio Code";        Id = "Microsoft.VisualStudioCode" }
    @{ No = 10; Ad = "UniGetUI";                  Id = "MartiCliment.UniGetUI" }
    @{ No = 11; Ad = "PowerToys";                 Id = "Microsoft.PowerToys" }
    @{ No = 12; Ad = "PowerShell 7";              Id = "Microsoft.PowerShell" }
    @{ No = 13; Ad = "Oracle Java Runtime";       Id = "Oracle.JavaRuntimeEnvironment" }
    @{ No = 14; Ad = "Microsoft PC Manager";      Id = "9PM860492SZD"; Kaynak = "msstore" }
    @{ No = 15; Ad = "Windows Terminal";          Id = "Microsoft.WindowsTerminal" }
    @{ No = 16; Ad = "Alpemix (Uzak Bağlantı)";   Id = "ALPEMIX_OZEL" }
)

# ===================== UYGULAMA KURULUM =====================

function Install-App {
    param([string]$Ad, [string]$Id, [string]$Kaynak = "winget")

    if ($Id -eq "ALPEMIX_OZEL") {
        Install-Alpemix
        return
    }

    # winget yoksa erken çık
    if (-not $WingetVar) {
        Write-Result $false "$Ad kurulamadı: winget bulunamadı."
        return
    }

    Write-Host "  $Ad kuruluyor..." -ForegroundColor Yellow

    # Store uygulamaları için msstore kaynağı, diğerleri için varsayılan winget kaynağı
    if ($Kaynak -eq "msstore") {
        $argumanlar = "install --id $Id --source msstore --accept-package-agreements --accept-source-agreements"
    } else {
        $argumanlar = "install --id $Id --silent --accept-package-agreements --accept-source-agreements"
    }

    $sonuc = Start-Process winget -ArgumentList $argumanlar -Wait -PassThru -NoNewWindow
    switch ($sonuc.ExitCode) {
        0           { Write-Result $true "$Ad başarıyla kuruldu." }
        -1978335189 { Write-Result $true "$Ad zaten güncel / yüklü." }
        default     { Write-Result $false "$Ad kurulamadı (Kod: $($sonuc.ExitCode))." }
    }
}

# ===================== ALPEMIX ÖZEL İNDİRME (İMZA KONTROLLÜ) =====================
function Install-Alpemix {
    Write-Host "  Alpemix indiriliyor..." -ForegroundColor Yellow
    try {
        $masaustu = [Environment]::GetFolderPath("Desktop")
        $hedef = Join-Path $masaustu "Alpemix.exe"
        $url = "https://www.alpemix.com/site/Alpemix.exe"

        try {
            [Net.ServicePointManager]::SecurityProtocol = `
                [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }

        Invoke-WebRequest -Uri $url -OutFile $hedef -UseBasicParsing -ErrorAction Stop

        if (-not (Test-Path $hedef)) {
            Write-Result $false "Alpemix indirilemedi."
            return
        }
        $boyutKB = [math]::Round((Get-Item $hedef).Length / 1KB, 1)
        if ($boyutKB -lt 50) {
            Write-Result $false "İndirilen dosya bozuk görünüyor ($boyutKB KB). İptal edildi."
            Remove-Item $hedef -Force -ErrorAction SilentlyContinue
            return
        }
        Write-Result $true "Alpemix indirildi: $hedef ($boyutKB KB)"

        $imza = Get-AuthenticodeSignature $hedef
        $imzaGuvenli = $false
        switch ($imza.Status) {
            "Valid" {
                $imzaci = $imza.SignerCertificate.Subject
                Write-Result $true "Dijital imza GEÇERLİ."
                Write-Host ("       İmzalayan: " + $imzaci) -ForegroundColor DarkGray
                $imzaGuvenli = $true
            }
            "NotSigned" {
                Write-Result $false "UYARI: Dosya dijital olarak İMZALANMAMIŞ."
            }
            default {
                Write-Result $false ("UYARI: İmza durumu güvensiz: " + $imza.Status)
            }
        }

        if (-not $imzaGuvenli) {
            Write-Host ""
            Write-Host "  Bu dosyanın imzası doğrulanamadı. Yalnızca kaynağa" -ForegroundColor Yellow
            Write-Host "  güveniyorsanız çalıştırın." -ForegroundColor Yellow
        }
        $ac = Read-Host "  Alpemix şimdi çalıştırılsın mı? (E/H)"
        if ($ac -eq "E" -or $ac -eq "e") {
            Start-Process $hedef
            Write-Result $true "Alpemix başlatıldı."
        } else {
            Write-Result $true "Çalıştırma iptal edildi. Dosya masaüstünde duruyor."
        }
    } catch {
        Write-Result $false "Alpemix indirilemedi: $($_.Exception.Message)"
    }
}

# ===================== TÜM UYGULAMALARI GÜNCELLE =====================

function Update-AllApps {
    Show-Header "TÜM UYGULAMALARI GÜNCELLE"

    if (-not $WingetVar) {
        Show-WingetHelp
        return
    }

    Write-Host "  Sistemde yüklü tüm programlar güncelleniyor..." -ForegroundColor "Yellow"
    Write-Host "  (winget upgrade --all)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "Tüm uygulamalar güncellensin mi?")) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    Write-Host ""
    Write-Host "  Güncelleme başlatılıyor, lütfen bekleyin..." -ForegroundColor $Tema.Vurgu
    Write-Host ""

    try {
        winget upgrade --all --include-unknown --accept-source-agreements --accept-package-agreements
        $kod = $LASTEXITCODE
    } catch {
        $kod = -1
    }

    # ===== ÖZET KUTUSU (DOKUNULMADI — çerçeve doğru eşleşmiş) =====
    Write-Host ""
    Show-Top
    Show-Line "  GÜNCELLEME ÖZETİ" $Tema.Baslik
    Show-Divider
    if ($kod -eq 0 -or $null -eq $kod) {
        Show-Line "  ✓ Güncelleme işlemi tamamlandı." $Tema.Basari
    } else {
        Show-Line "  ⚠ Bazı paketler güncellenemedi (çıkış kodu: $kod)." $Tema.Hata
    }
    Show-Line "  Not: Güncellenecek paket yoksa 'her şey güncel' demektir." $Tema.Soluk
    Show-Bottom

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
# ===================== SİSTEM FONKSİYONLARI =====================

function New-AdminFolders {
    Show-Header "YÖNETİM KLASÖRLERİ OLUŞTUR"
    Write-Host ""
    $onay = Read-Host "  Masaüstünde Admin ve GodMode klasörleri oluşturulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    $masaustu = [Environment]::GetFolderPath("Desktop")
    try {
        $adminYol   = Join-Path $masaustu "Yönetim Araçları.{D20EA4E1-3957-11d2-A40B-0C5020524153}"
        $godmodeYol = Join-Path $masaustu "GodMode.{ED7BA470-8E54-465E-825C-99712043E01C}"
        if (-not (Test-Path $adminYol))   { New-Item -Path $adminYol -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $godmodeYol)) { New-Item -Path $godmodeYol -ItemType Directory -Force | Out-Null }
        Write-Result $true "Yönetim ve GodMode klasörleri masaüstünde oluşturuldu."
    } catch {
        Write-Result $false "Klasör oluşturulamadı: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Show-SystemInfo {
    Show-Header "SİSTEM BİLGİLERİ"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        Write-Host ("  Bilgisayar : " + $cs.Name)          -ForegroundColor $Tema.Baslik
        Write-Host ("  İşletim S. : " + $os.Caption)       -ForegroundColor $Tema.Baslik
        Write-Host ("  Sürüm      : " + $os.Version)        -ForegroundColor $Tema.Metin
        Write-Host ("  İşlemci    : " + $cpu.Name.Trim())   -ForegroundColor $Tema.Metin
        Write-Host ("  RAM        : " + $ram + " GB")        -ForegroundColor $Tema.Metin
        Write-Host ("  Üretici    : " + $cs.Manufacturer)   -ForegroundColor $Tema.Metin
    } catch {
        Write-Host ("  Bilgi alınamadı: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Show-DiskSummary {
    Show-Header "DİSK ÖZETİ"
    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $toplam = [math]::Round($_.Size / 1GB, 1)
            $bos    = [math]::Round($_.FreeSpace / 1GB, 1)
            $dolu   = $toplam - $bos
            $yuzde  = if ($toplam -gt 0) { [math]::Round(($dolu / $toplam) * 100) } else { 0 }
            Write-Host ("  Sürücü " + $_.DeviceID + "  Toplam: $toplam GB  Boş: $bos GB  (%$yuzde dolu)") -ForegroundColor $Tema.Baslik
        }
    } catch {
        Write-Host ("  Disk bilgisi alınamadı.") -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Show-DiskHealth {
    Show-Header "DİSK SAĞLIĞI (SMART)"
    try {
        Get-PhysicalDisk | ForEach-Object {
            $durum = $_.HealthStatus
            $renk = if ($durum -eq "Healthy") { $Tema.Basari } else { $Tema.Hata }
            Write-Host ("  " + $_.FriendlyName + "  Durum: " + $durum) -ForegroundColor $renk
        }
    } catch {
        Write-Host ("  Disk sağlık bilgisi alınamadı.") -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Show-Startup {
    Show-Header "BAŞLANGIÇ PROGRAMLARI"

    # --- Kayıtlı başlangıç programlarını listele + say ---
    $sayac = 0
    try {
        Get-CimInstance Win32_StartupCommand | ForEach-Object {
            $sayac++
            Write-Host ("  " + $_.Name + "  ->  " + $_.Command) -ForegroundColor $Tema.Metin
        }
        if ($sayac -eq 0) {
            Write-Host "  Kayıtlı başlangıç programı bulunamadı." -ForegroundColor $Tema.Soluk
        } else {
            Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
            Write-Host ("  Toplam $sayac başlangıç programı bulundu.") -ForegroundColor $Tema.Vurgu
        }
    } catch {
        Write-Host "  Başlangıç programları alınamadı." -ForegroundColor $Tema.Hata
    }

    Write-Host ""

    # --- E/H sorusu: Başlangıç ayar ekranını açmak ister mi? ---
    Write-Host "  Windows Başlangıç ayarlarını açmak ister misiniz? " -NoNewline -ForegroundColor $Tema.Metin
    Write-Host "(E/H)" -ForegroundColor $Tema.Vurgu
    $cevap = Read-Host "  Seçiminiz"

    if ($cevap -match '^[EeYy]') {
        Write-Host ""
        Write-Host "  Windows Başlangıç ayarları açılıyor..." -ForegroundColor $Tema.Metin
        try {
            Start-Process "ms-settings:startupapps" -ErrorAction Stop
            Write-Result $true "Ayarlar > Başlangıç sayfası açıldı."
        } catch {
            try {
                Start-Process "taskmgr.exe" -ArgumentList "/0 /startup" -ErrorAction Stop
                Write-Result $true "Görev Yöneticisi (Başlangıç sekmesi) açıldı."
            } catch {
                Write-Result $false "Başlangıç ayarları açılamadı: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host ""
        Write-Result $true "Başlangıç ayarları açılmadı. Ana menüye dönülüyor."
    }

    Read-Host "`n  Devam etmek için Enter'a basın"
}

function Start-WindowsUpdate {
    Show-Header "WINDOWS GÜNCELLEMELERİ"
    Write-Host ""
    $onay = Read-Host "  Windows güncellemeleri aranıp kurulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    try {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Progress -Activity "Windows Update" -Status "PSWindowsUpdate modülü kuruluyor..." -PercentComplete 10
            Write-Host "  [1/3] PSWindowsUpdate modülü kuruluyor..." -ForegroundColor Yellow
            Install-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue | Out-Null
            Install-Module PSWindowsUpdate -Force -Scope CurrentUser -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Write-Host "  [1/3] PSWindowsUpdate modülü hazır." -ForegroundColor DarkGray
        }

        Write-Progress -Activity "Windows Update" -Status "Modül yükleniyor..." -PercentComplete 40
        Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue

        Write-Progress -Activity "Windows Update" -Status "Güncellemeler aranıyor ve kuruluyor..." -PercentComplete 70
        Write-Host "  [2/3] Güncellemeler aranıyor..." -ForegroundColor Yellow
        Write-Host "  [3/3] Bulunanlar kuruluyor (bu işlem uzun sürebilir)..." -ForegroundColor Yellow
        Write-Host ""

        # -Verbose ile her güncellemenin durumu ekrana yansır
        Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -Verbose

        Write-Progress -Activity "Windows Update" -Completed
        Write-Host ""
        Write-Result $true "Windows güncelleme işlemi tamamlandı."
    } catch {
        Write-Progress -Activity "Windows Update" -Completed
        Write-Result $false "Güncelleme yapılamadı: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Reset-Network {
    Show-Header "AĞ SIFIRLAMA"
    Write-Host ""
if (-not (Confirm-Islem "Ağ ayarları sıfırlanacak (DNS, Winsock, IP). Emin misiniz?")) {
    Write-Result $false "İşlem iptal edildi."
    Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
}

    try {
        ipconfig /flushdns | Out-Null
        netsh winsock reset | Out-Null
        netsh int ip reset | Out-Null
        Write-Result $true "Ağ ayarları sıfırlandı. Bilgisayarı yeniden başlatın."
    } catch {
        Write-Result $false "Ağ sıfırlanamadı: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function New-RestorePoint {
    Show-Header "SİSTEM GERİ YÜKLEME NOKTASI"
    Write-Host ""
    $onay = Read-Host "  Sistem geri yükleme noktası oluşturulsun mu? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Bilgisayar Araci - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-Result $true "Geri yükleme noktası oluşturuldu."
    } catch {
        Write-Result $false "Geri yükleme noktası oluşturulamadı: $($_.Exception.Message)"
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Clear-PrintQueue {
    Show-Header "YAZICI KUYRUĞUNU TEMİZLE"
    Write-Host ""
    $onay = Read-Host "  Yazıcı kuyruğu temizlenecek. Onaylıyor musunuz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    try {
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler -ErrorAction SilentlyContinue
        Write-Result $true "Yazıcı kuyruğu temizlendi."
    } catch {
        Write-Result $false "Yazıcı kuyruğu temizlenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Show-HealthSummary {
    Show-Header "SİSTEM SAĞLIK ÖZETİ"
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $bosRam = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 1)
        $cTop = [math]::Round($cDisk.Size / 1GB, 1)
        $uptime = (Get-Date) - $os.LastBootUpTime

        Write-Host ("  RAM        : " + $ram + " GB  (Boş: " + $bosRam + " GB)") -ForegroundColor $Tema.Baslik
        Write-Host ("  C: Disk    : " + $cTop + " GB  (Boş: " + $cBos + " GB)") -ForegroundColor $Tema.Baslik
        Write-Host ("  Çalışma S. : " + $uptime.Days + " gün " + $uptime.Hours + " saat") -ForegroundColor $Tema.Metin

        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
        if ($cYuzde -gt 90) { Write-Host "  ⚠ C: sürücüsü neredeyse dolu!" -ForegroundColor $Tema.Hata }
        elseif ($cYuzde -gt 75) { Write-Host "  ⚠ C: sürücüsünde yer azalıyor." -ForegroundColor Yellow }
        else { Write-Host "  ✓ Disk durumu iyi." -ForegroundColor $Tema.Basari }

        if ($bosRam -lt 1) { Write-Host "  ⚠ Boş RAM düşük!" -ForegroundColor $Tema.Hata }
        else { Write-Host "  ✓ RAM durumu iyi." -ForegroundColor $Tema.Basari }
    } catch {
        Write-Host ("  Sağlık özeti alınamadı: " + $_.Exception.Message) -ForegroundColor $Tema.Hata
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

# ===================== GÜVENLİK: KORUNAN YOLLAR (bir kez tanımlanır) =====================
$Global:YasakliYollar = @(
    "$env:SystemDrive\",
    "$env:SystemRoot",
    "$env:SystemDrive",
    "C:\",
    "C:\Windows",
    [Environment]::GetFolderPath("Desktop"),
    [Environment]::GetFolderPath("MyDocuments"),
    [Environment]::GetFolderPath("UserProfile")
)

function Test-GuvenliYol {
    param([string]$Yol)
    if ([string]::IsNullOrWhiteSpace($Yol)) { return $false }
    $tam = [System.IO.Path]::GetFullPath($Yol).TrimEnd('\')
    if ($tam.Length -lt 8) { return $false }
    foreach ($y in $Global:YasakliYollar) {
        if ([string]::IsNullOrWhiteSpace($y)) { continue }
        $yTam = [System.IO.Path]::GetFullPath($y).TrimEnd('\')
        if ($tam -ieq $yTam) { return $false }
    }
    if ($tam -imatch "Temp$" -or $tam -imatch "Prefetch$") { return $true }
    return $false
}

# ===================== TEMİZLİK FONKSİYONLARI =====================

function Clean-Temp {
    Show-Header "GEÇİCİ DOSYALARI TEMİZLE"

    if (-not (Confirm-Islem "Geçici dosyalar temizlensin mi?")) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    # Güvenli temizlenecek konumlar
    $hedefler = @(
        @{ Ad = "Kullanıcı TEMP";     Yol = $env:TEMP }
        @{ Ad = "Windows TEMP";       Yol = "$env:WINDIR\Temp" }
        @{ Ad = "Prefetch";           Yol = "$env:WINDIR\Prefetch" }
        @{ Ad = "Son Kullanılanlar";  Yol = "$env:APPDATA\Microsoft\Windows\Recent" }
    )

    # GÜVENLİK: bu kök yollar asla silinmemeli
    $yasakli = @("C:\", "C:\Windows", $env:WINDIR, $env:SystemRoot, "C:\Program Files", "C:\Program Files (x86)")

    $kazanc = 0
    Write-Host ""

    foreach ($k in $hedefler) {
        if ([string]::IsNullOrWhiteSpace($k.Yol) -or -not (Test-Path $k.Yol)) {
            Write-Result $false ($k.Ad + " bulunamadı, atlandı.")
            continue
        }

        # GÜVENLİK kontrolü: hedef yasaklı kök yollardan biriyse atla
        $tamYol = (Resolve-Path $k.Yol -ErrorAction SilentlyContinue).Path
        if ($tamYol -and ($yasakli -contains $tamYol.TrimEnd('\'))) {
            Write-Result $false ($k.Ad + " GÜVENLİK nedeniyle atlandı: " + $k.Yol)
            continue
        }

        $oncesi = Get-FolderSizeMB $k.Yol
        try {
            Get-ChildItem -Path $k.Yol -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            $sonrasi = Get-FolderSizeMB $k.Yol
            $fark = [math]::Max(0, $oncesi - $sonrasi)
            $kazanc += $fark
            Write-Result $true ($k.Ad + " temizlendi.")
        } catch {
            Write-Result $false ($k.Ad + " temizlenirken hata: " + $_.Exception.Message)
        }
    }

    Write-Host ""
    Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
    Write-Result $true ("Toplam temizlenen alan: $kazanc MB")
    Write-Host "  Not: Prefetch silindiği için ilk açılışlar biraz" -ForegroundColor $Tema.Soluk
    Write-Host "  yavaş olabilir, sonra normale döner." -ForegroundColor $Tema.Soluk

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Clean-Logs {
    Show-Header "OLAY GÜNLÜKLERİNİ TEMİZLE"

    Write-Host "  Windows olay günlükleri temizleniyor..." -ForegroundColor "Yellow"
    Write-Host "  (Bu işlem birkaç dakika sürebilir, lütfen bekleyin)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "Tüm olay günlükleri temizlensin mi?")) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    Write-Host ""

    try {
        $loglar = @(wevtutil el 2>$null)
        $toplam = $loglar.Count

        if ($toplam -eq 0) {
            Write-Result $false "Temizlenecek olay günlüğü bulunamadı."
            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
            return
        }

        $sayac    = 0
        $basarili = 0

        foreach ($log in $loglar) {
            $sayac++

            # --- CANLI YÜZDELİ ÇUBUK ---
            $yuzde = [math]::Round(($sayac / $toplam) * 100)
            $dolu  = [math]::Round($yuzde / 100 * 30)
            $cubuk = ("█" * $dolu) + ("░" * (30 - $dolu))
            Write-Host ("`r  [$cubuk]  %$yuzde  ($sayac/$toplam)   ") -ForegroundColor Yellow -NoNewline

            wevtutil cl "$log" 2>$null
            if ($LASTEXITCODE -eq 0) { $basarili++ }
        }

        # Çubuğu %100 olarak kapat
        Write-Host ("`r  [" + ("█" * 30) + "]  %100  tamamlandı           ") -ForegroundColor Green
        Write-Host ""

        Write-Result $true "$basarili / $toplam olay günlüğü temizlendi."
        if ($basarili -lt $toplam) {
            Write-Host "  Not: Bazı korumalı günlükler temizlenemez (normaldir)." -ForegroundColor $Tema.Soluk
        }
    } catch {
        Write-Result $false ("Günlükler temizlenirken hata: " + $_.Exception.Message)
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Clean-WinUpdate {
    Show-Header "WINDOWS UPDATE ÖNBELLEĞİNİ TEMİZLE"
    try {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        Write-Result $true "Windows Update önbelleği temizlendi."
    } catch {
        Write-Result $false "Önbellek temizlenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Clean-RecycleBin {
    Show-Header "GERİ DÖNÜŞÜM KUTUSU TEMİZLE"
    Write-Host ""

    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Host "  ✓  Geri dönüşüm kutusu temizlendi" -ForegroundColor $Tema.Basari
    }
    catch {
        # "Yol bulunamadı" / "zaten boş" hataları aslında BAŞARI demektir
        if ($_.Exception.Message -match "belirtilen yolu bulamıyor" -or
            $_.Exception.Message -match "cannot find the path" -or
            $_.Exception.Message -match "Recycle Bin.*empty" -or
            $_.Exception.Message -match "boş") {
            Write-Host "  ✓  Geri dönüşüm kutusu temizlendi" -ForegroundColor $Tema.Basari
        }
        else {
            # Gerçek bir hata varsa göster
            Write-Host "  ✗  Geri dönüşüm kutusu boşaltılamadı: $($_.Exception.Message)" -ForegroundColor $Tema.Hata
        }
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Clean-Disk {
    Show-Header "DİSK TEMİZLEME ARACI (cleanmgr)"
    try {
        Start-Process cleanmgr -ArgumentList "/sagerun:1" -Wait
        Write-Result $true "Disk Temizleme aracı çalıştırıldı."
    } catch {
        Write-Result $false "Disk Temizleme çalıştırılamadı: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Clean-GpuLeftovers {
    Show-Header "EKRAN KARTI SÜRÜCÜ ARTIKLARINI TEMİZLE"

    Write-Host "  Bu işlem AMD / NVIDIA / Intel kurulum artıklarını temizler." -ForegroundColor $Tema.Metin
    Write-Host "  (Yüklü sürücüler etkilenmez, yalnızca kurulum klasörleri)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "Sürücü kurulum artıkları temizlensin mi?")) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    # Temizlenecek bilinen kurulum artık klasörleri
    $hedefler = @(
        "C:\AMD",
        "C:\NVIDIA",
        "$env:WINDIR\Temp\NVIDIA Corporation",
        "$env:LOCALAPPDATA\Temp\NVIDIA Corporation",
        "C:\Intel"
    )

    # GÜVENLİK: kök yollar asla silinmemeli
    $yasakli = @("C:\", "C:\Windows", $env:WINDIR, $env:SystemRoot, "C:\Program Files", "C:\Program Files (x86)")

    $kazanc = 0
    Write-Host ""

    foreach ($h in $hedefler) {
        if ([string]::IsNullOrWhiteSpace($h) -or -not (Test-Path $h)) {
            Write-Result $true ((Split-Path $h -Leaf) + " klasörü yok, atlandı.")
            continue
        }

        # GÜVENLİK kontrolü
        $tam = (Resolve-Path $h -ErrorAction SilentlyContinue).Path
        if ($tam -and ($yasakli -contains $tam.TrimEnd('\'))) {
            Write-Result $false ("GÜVENLİK nedeniyle atlandı: " + $tam)
            continue
        }

        $ad = Split-Path $h -Leaf
        $oncesi = Get-FolderSizeMB $h
        try {
            Remove-Item -Path $h -Recurse -Force -ErrorAction SilentlyContinue
            $kazanc += $oncesi
            Write-Result $true ($ad + " kurulum artıkları temizlendi.")
        } catch {
            Write-Result $false ($ad + " temizlenirken hata: " + $_.Exception.Message)
        }
    }

    Write-Host ""
    Write-Host ("  " + ("-" * 50)) -ForegroundColor $Tema.Cerceve
    Write-Result $true ("Toplam temizlenen alan: $kazanc MB")

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Repair-SystemFiles {
    Show-Header "SİSTEM DOSYALARINI ONAR (DISM + SFC)"

    Write-Host "  Sistem dosyaları taranıp onarılıyor..." -ForegroundColor "Yellow"
    Write-Host "  (DISM + SFC — bu işlem 10-20 dakika sürebilir)" -ForegroundColor $Tema.Soluk
    Write-Host ""

    if (-not (Confirm-Islem "Sistem dosyası onarımı başlatılsın mı?")) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    Write-Host ""

    # ===== 1) DISM RestoreHealth =====
    Write-Host "  [1/2] DISM /RestoreHealth çalışıyor..." -ForegroundColor $Tema.Vurgu
    $dismKod = Invoke-YuzdeliIslem -Dosya "DISM.exe" `
               -Argumanlar "/Online /Cleanup-Image /RestoreHealth" -NullTemizle
    if ($dismKod -eq 0) {
        Write-Result $true "DISM onarımı tamamlandı."
    } else {
        Write-Result $false "DISM hata koduyla bitti: $dismKod"
    }

    Write-Host ""

    # ===== 2) SFC ScanNow =====
    Write-Host "  [2/2] SFC /ScanNow çalışıyor..." -ForegroundColor $Tema.Vurgu
    $sfcKod = Invoke-YuzdeliIslem -Dosya "sfc.exe" -Argumanlar "/scannow" -NullTemizle
    if ($sfcKod -eq 0) {
        Write-Result $true "SFC taraması tamamlandı."
    } else {
        Write-Result $false "SFC hata koduyla bitti: $sfcKod"
    }

    Write-Host ""
    Write-Host "  Not: Onarım sonrası bilgisayarı yeniden başlatmanız önerilir." -ForegroundColor $Tema.Soluk

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
# ===================== GÜVENLİ USB OLUŞTUR (Seçenek C - Fiziksel Disk Bazlı) =====================
function Protect-USB {
    Show-Header "USB DİSK KORUMA / BİÇİMLENDİRME"

    # Diskleri listele
    $diskler = Get-Disk | Where-Object { $_.BusType -eq 'USB' }

    if (-not $diskler) {
        Write-Host "  Bağlı USB disk bulunamadı." -ForegroundColor $Tema.Hata
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    Write-Host "  Bağlı USB diskler:" -ForegroundColor $Tema.Vurgu
    Write-Host ""
    foreach ($d in $diskler) {
        $boyutGB = [math]::Round($d.Size / 1GB, 1)
        Write-Host ("   Disk {0}  |  {1}  |  {2} GB" -f $d.Number, $d.FriendlyName, $boyutGB) -ForegroundColor $Tema.Metin
    }
    Write-Host ""

    $secim = Read-Host "  İşlem yapılacak disk numarasını girin (iptal için q)"
    if ($secim -eq 'q' -or [string]::IsNullOrWhiteSpace($secim)) {
        Write-Result $false "İşlem iptal edildi."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    $diskNo = 0
    if (-not [int]::TryParse($secim, [ref]$diskNo)) {
        Write-Result $false "Geçersiz disk numarası."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    $hedefDisk = $diskler | Where-Object { $_.Number -eq $diskNo }
    if (-not $hedefDisk) {
        Write-Result $false "Belirtilen numarada USB disk bulunamadı."
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    # ===== GÜVENLİK KONTROLLERİ =====
    if ($hedefDisk.BusType -ne 'USB') {
        Write-Host "  ⚠ UYARI: Bu disk USB değil! İşlem güvenlik nedeniyle durduruldu." -ForegroundColor $Tema.Hata
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    $diskBoyutGB = [math]::Round($hedefDisk.Size / 1GB, 1)
    if ($diskBoyutGB -gt 512) {
        Write-Host "  ⚠ UYARI: Disk çok büyük ($diskBoyutGB GB). Harici HDD olabilir." -ForegroundColor $Tema.Hata
        if (-not (Confirm-Islem "Yine de devam edilsin mi?")) {
            Write-Result $false "İşlem iptal edildi."
            Read-Host "  Devam etmek için Enter'a basın"
            return
        }
    }

    # ===== İŞLEM TİPİ SEÇİMİ =====
    Write-Host ""
    Write-Host ("  Seçilen: Disk {0} - {1} ({2} GB)" -f $hedefDisk.Number, $hedefDisk.FriendlyName, $diskBoyutGB) -ForegroundColor $Tema.Vurgu
    Write-Host ""
    Write-Host "  Ne yapmak istersiniz?" -ForegroundColor $Tema.Baslik
    Write-Host "   1) Bölümleri birleştir ve biçimlendir (TÜM VERİ SİLİNİR)" -ForegroundColor $Tema.Metin
    Write-Host "   2) Bölümleri listele (salt okuma, güvenli)" -ForegroundColor $Tema.Metin
    Write-Host "   q) İptal" -ForegroundColor $Tema.Soluk
    Write-Host ""

    $islemTipi = Read-Host "  Seçiminiz"

    switch ($islemTipi) {

        "1" {
            Write-Host ""
            Write-Host ("  " + ("═" * 50)) -ForegroundColor $Tema.Hata
            Write-Host "  ⚠ KALICI VERİ SİLME İŞLEMİ" -ForegroundColor $Tema.Hata
            Write-Host ("   Disk   : {0}" -f $hedefDisk.FriendlyName) -ForegroundColor $Tema.Metin
            Write-Host ("   Boyut  : {0} GB" -f $diskBoyutGB) -ForegroundColor $Tema.Metin
            Write-Host "   Silinecek: Diskteki TÜM bölümler ve veriler" -ForegroundColor $Tema.Metin
            Write-Host ("  " + ("═" * 50)) -ForegroundColor $Tema.Hata
            Write-Host ""

            $onay = Read-Host "  Onaylamak için diskin adını yazın ('$($hedefDisk.FriendlyName)')"
            if ($onay -ne $hedefDisk.FriendlyName) {
                Write-Result $false "Disk adı eşleşmedi. İşlem güvenlik nedeniyle iptal edildi."
                Read-Host "  Devam etmek için Enter'a basın"
                return
            }

            try {
                Write-Host ""
                Write-Host "  İşlem yapılıyor, lütfen bekleyin..." -ForegroundColor $Tema.Vurgu

                # Diski temizle, tek bölüm oluştur, NTFS biçimlendir
                Clear-Disk -Number $diskNo -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
                Initialize-Disk -Number $diskNo -PartitionStyle MBR -ErrorAction SilentlyContinue
                $yeniBolum = New-Partition -DiskNumber $diskNo -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
                Format-Volume -Partition $yeniBolum -FileSystem NTFS -NewFileSystemLabel "USB" -Confirm:$false -ErrorAction Stop | Out-Null

                Write-Host ""
                Write-Result $true ("İşlem tamamlandı. Yeni sürücü harfi: " + $yeniBolum.DriveLetter + ":")
            } catch {
                Write-Result $false ("İşlem başarısız: " + $_.Exception.Message)
            }

            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
        }

        "2" {
            Write-Host ""
            Write-Host "  Disk üzerindeki bölümler:" -ForegroundColor $Tema.Vurgu
            Write-Host ""
            try {
                $bolumler = Get-Partition -DiskNumber $diskNo -ErrorAction Stop
                foreach ($b in $bolumler) {
                    $bBoyutGB = [math]::Round($b.Size / 1GB, 2)
                    $harf = if ($b.DriveLetter) { $b.DriveLetter + ":" } else { "(harf yok)" }
                    Write-Host ("   Bölüm {0}  |  {1}  |  {2} GB" -f $b.PartitionNumber, $harf, $bBoyutGB) -ForegroundColor $Tema.Metin
                }
            } catch {
                Write-Result $false ("Bölümler listelenemedi: " + $_.Exception.Message)
            }

            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
        }

        default {
            Write-Result $false "İşlem iptal edildi."
            Read-Host "  Devam etmek için Enter'a basın"
        }
    }
}
# ===================== DİSK KONTROL VE ONARIM (chkdsk) =====================
function Repair-Disk {
    Show-Header "DİSK ONARIMI (chkdsk)"

    # --- Fiziksel diskleri topla ---
    try {
        $diskler = Get-Disk | Sort-Object Number -ErrorAction Stop
    } catch {
        Write-Result $false "Disk bilgisi alınamadı: $($_.Exception.Message)"
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    if (-not $diskler) {
        Write-Result $false "Hiç disk bulunamadı."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    $harfListesi = @()
    $sayac = 0

    Write-Host ""
    foreach ($disk in $diskler) {
        # --- Disk başlığı (model + tür + boyut) ---
        $model = if ($disk.FriendlyName) { $disk.FriendlyName.Trim() } else { 'Bilinmeyen' }
        $busType = if ($disk.BusType) { $disk.BusType } else { '?' }
        $boyutGB = [math]::Round($disk.Size / 1GB, 2)
        $sistemMi = if ($disk.IsBoot -or $disk.IsSystem) { ' [SİSTEM DİSKİ]' } else { '' }

        Write-Host ("  [Disk $($disk.Number)] $model") -ForegroundColor $Tema.Baslik
        Write-Host ("     $busType - $boyutGB GB$sistemMi") -ForegroundColor $Tema.Soluk

        # --- Bu diske ait bölümler ---
        $bolumler = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveLetter }

        if (-not $bolumler) {
            Write-Host "        (harflendirilmis bolum yok)" -ForegroundColor $Tema.Soluk
            Write-Host ""
            continue
        }

        foreach ($bolum in $bolumler) {
            $harf = $bolum.DriveLetter
            $vol = Get-Volume -DriveLetter $harf -ErrorAction SilentlyContinue
            $etiket = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { 'etiket yok' }
            $fs = if ($vol.FileSystem) { $vol.FileSystem } else { '?' }
            $bolBoyut = if ($vol.Size) { [math]::Round($vol.Size / 1GB, 2) } else { 0 }
            $sysMi = if ($harf -eq $env:SystemDrive.TrimEnd(':')) { ' [SİSTEM]' } else { '' }

            $sayac++
            $harfListesi += [PSCustomObject]@{
                No     = $sayac
                Harf   = $harf
                FS     = $fs
                Sistem = ($harf -eq $env:SystemDrive.TrimEnd(':'))
            }

            Write-Host ("     $sayac) $harf`: $etiket - $bolBoyut GB - $fs$sysMi") -ForegroundColor $Tema.Metin
        }
        Write-Host ""
    }

    if ($sayac -eq 0) {
        Write-Result $false "Taranabilecek harflendirilmis bolum yok."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    # --- Kullanıcı harf seçsin ---
    $secim = Read-Host "  Taramak istediğin bölüm numarası (İptal için 0)"
    if ($secim -eq '0' -or [string]::IsNullOrWhiteSpace($secim)) {
        Write-Result $false "İşlem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    $secilen = $harfListesi | Where-Object { $_.No -eq [int]$secim }
    if (-not $secilen) {
        Write-Result $false "Geçersiz seçim."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    $harf = $secilen.Harf
    $fs = $secilen.FS

    # --- exFAT / FAT uyarısı ---
    if ($fs -in @('exFAT', 'FAT', 'FAT32')) {
        Write-Host ""
        Write-Host "  UYARI: $harf`: sürücüsü $fs formatında." -ForegroundColor Yellow
        Write-Host "  chkdsk $fs üzerinde sınırlı çalışır (/R yok)." -ForegroundColor $Tema.Soluk
        Write-Host ""
    }

    # --- Tarama modu ---
    Write-Host "  Tarama modu seç:" -ForegroundColor $Tema.Baslik
    Write-Host "     1) Hızlı  (/F /X) - hataları düzelt" -ForegroundColor $Tema.Metin
    Write-Host "     2) Derin  (/R /X) - bozuk sektör (çok uzun)" -ForegroundColor $Tema.Metin
    Write-Host ""
    $mod = Read-Host "  Mod (1/2)"

    if ($fs -in @('exFAT', 'FAT', 'FAT32') -and $mod -eq '2') {
        Write-Result $false "$fs formatında /R yok. Hızlı moda geçiliyor."
        $mod = '1'
    }

    $parametre = if ($mod -eq '2') { '/R /X' } else { '/F /X' }

    # --- Sistem diski kontrolü ---
    if ($secilen.Sistem) {
        Write-Host ""
        Write-Host "  $harf`: SİSTEM sürücüsü. Şimdi taranamaz." -ForegroundColor Yellow
        Write-Host "  Yeniden başlatmada taranacak şekilde planlanabilir." -ForegroundColor $Tema.Metin
        Write-Host ""
        $ok = Read-Host "  Planlansın mı? (E/H)"
        if ($ok.ToUpper() -eq 'E') {
            cmd /c "echo Y| chkdsk $harf`: $parametre" | Out-Null
            Write-Result $true "$harf`: yeniden başlatmada taranacak."
        } else {
            Write-Result $false "İşlem iptal edildi."
        }
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    # --- Normal sürücü: /X bağlantıyı keser ---
    Write-Host ""
    Write-Host "  $harf`: taranacak (mod: $parametre)." -ForegroundColor $Tema.Baslik
    Write-Host "  /X sürücü bağlantısını geçici keser." -ForegroundColor $Tema.Soluk
    Write-Host "  Açık dosyalar kapanacak. Devam edilsin mi?" -ForegroundColor $Tema.Metin
    Write-Host ""
    $ok = Read-Host "  Devam? (E/H)"
    if ($ok.ToUpper() -ne 'E') {
        Write-Result $false "İşlem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    # --- chkdsk çalıştır ---
    Write-Host ""
    Write-Host "  chkdsk çalışıyor, lütfen bekleyin..." -ForegroundColor Cyan
    Write-Host ""

    $sonuc = Start-Process -FilePath "chkdsk.exe" `
                           -ArgumentList "$harf`:", $parametre.Split(' ') `
                           -NoNewWindow -Wait -PassThru

    Write-Host ""
    if ($sonuc.ExitCode -eq 0) {
        Write-Result $true "$harf`: temiz, hata bulunamadı."
    } elseif ($sonuc.ExitCode -eq 1) {
        Write-Result $true "$harf`: hatalar bulundu ve düzeltildi."
    } else {
        Write-Result $false "$harf`: tarama bitti (Kod: $($sonuc.ExitCode))."
    }

    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
# ===================== SÜRÜCÜ VE UYGULAMA YÖNETİMİ =====================

function Backup-Drivers {
    Show-Header "SÜRÜCÜ YEDEKLE"
    $hedef = Select-Folder "Sürücülerin yedekleneceği klasörü seçin"
    if (-not $hedef) { Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return }

    $klasor = Join-Path $hedef ("Surucu_Yedek_" + (Get-Date -Format "yyyyMMdd_HHmm"))
    Write-Host ""
    $onay = Read-Host "  Sürücüler '$klasor' klasörüne yedeklenecek. Onaylıyor musunuz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    $eskiProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        New-Item -Path $klasor -ItemType Directory -Force | Out-Null

        Write-Host "  Sürücüler yedekleniyor, lütfen bekleyin..." -ForegroundColor Yellow
        Write-Host "  (Her yedeklenen sürücü canlı listelenecek.)" -ForegroundColor DarkGray
        Write-Host ""

        # Export-WindowsDriver her sürücü için bir nesne döndürür.
        # Pipe ile akıtıp her gelen sürücüde sayacı artır + canlı listele.
       $sayac = 0
        Export-WindowsDriver -Online -Destination $klasor -ErrorAction Stop | ForEach-Object {
            $sayac++
            $no = $sayac.ToString().PadLeft(3)
            # >>> DÜZELTME: OriginalFileName null/boş olabilir -> güvenli kontrol
            $ad = if ($_.OriginalFileName) { Split-Path $_.OriginalFileName -Leaf } else { "(bilinmeyen sürücü)" }
            $sinif = if ($_.ClassName) { $_.ClassName } else { "Genel" }
            Write-Host ("  [" + $no + "] ") -ForegroundColor Cyan -NoNewline
            Write-Host $ad -ForegroundColor Gray -NoNewline
            Write-Host ("   (" + $sinif + ")") -ForegroundColor DarkGray

            Write-Progress -Activity "Sürücüler yedekleniyor" `
                           -Status "$sayac sürücü yedeklendi..." `
                           -CurrentOperation $ad
        }
        Write-Progress -Activity "Sürücüler yedekleniyor" -Completed

        Write-Host ""
        if ($sayac -gt 0) {
            Write-Result $true "$sayac sürücü yedeklendi: $klasor"
        } else {
            Write-Result $false "Yedeklenecek sürücü bulunamadı."
        }
    } catch {
        Write-Result $false "Sürücü yedeklenemedi: $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $eskiProgress
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

function Restore-Drivers {
    Show-Header "SÜRÜCÜ GERİ YÜKLE"
    $kaynak = Select-Folder "Yedeklenmiş sürücü klasörünü seçin"
    if (-not $kaynak) { Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return }

    Write-Host ""
    $onay = Read-Host "  Sürücüler '$kaynak' klasöründen geri yüklenecek. Emin misiniz? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."; Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }
    try {
        # .inf var mı kontrol et
        $infVar = Get-ChildItem -Path $kaynak -Filter *.inf -Recurse -ErrorAction SilentlyContinue
        if (-not $infVar) {
            Write-Result $false "Seçilen klasörde .inf sürücü dosyası bulunamadı."
            Write-Host ""
            Read-Host "  Devam etmek için Enter'a basın"
            return
        }

        Write-Host "  Sürücüler yükleniyor, lütfen bekleyin..." -ForegroundColor Yellow
        pnputil /add-driver "$kaynak\*.inf" /subdirs /install
        $kod = $LASTEXITCODE

        # >>> REVİZE: pnputil çıkış kodlarını doğru yorumla
        #   0    = başarılı
        #   259  = ERROR_NO_MORE_ITEMS -> eklenecek YENİ sürücü yok (zaten güncel) — başarı
        #   3010 = başarılı, yeniden başlatma gerekli
        switch ($kod) {
            0 {
                Write-Result $true "Sürücüler geri yüklendi."
            }
            259 {
                Write-Result $true "Tüm sürücüler zaten güncel — yüklenecek yeni sürücü yoktu."
            }
            3010 {
                Write-Result $true "Sürücüler geri yüklendi. Değişikliklerin tamamlanması için yeniden başlatın."
            }
            default {
                Write-Result $false "Sürücü geri yükleme tamamlandı ancak bazı sürücüler yüklenemedi (Kod: $kod)."
            }
        }
    } catch {
        Write-Result $false "Sürücü geri yüklenemedi: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}

# ===================== UYGULAMA ARA VE KUR (winget search) =====================
function Search-App {
    Show-Header "UYGULAMA ARA (winget)"

    # --- Arama terimi al ---
    $arama = Read-Host "  Aranacak uygulama adi (Iptal icin bos Enter)"
    if ([string]::IsNullOrWhiteSpace($arama)) {
        Write-Host "  Islem iptal edildi." -ForegroundColor $Tema.Soluk
        Read-Host "  Devam etmek icin Enter'a basin"
        return
    }

    # --- Sistem durumu (Store var mi?) ---
    $storeVar = $null -ne (Get-AppxPackage -Name "Microsoft.WindowsStore" -ErrorAction SilentlyContinue)
    if ($storeVar) {
        Write-Host "  Sistem: Normal (Store'lu)" -ForegroundColor $Tema.Metin
    } else {
        Write-Host "  Sistem: Store yok (sadece winget kaynaklari)" -ForegroundColor $Tema.Metin
    }

    Write-Host ""
    Write-Host "  '$arama' araniyor..." -ForegroundColor $Tema.Vurgu
    Write-Host ""

    # --- Arama yap (tek cagri, tum kaynaklar) ---
    $sonuc = winget search $arama 2>&1 | Out-String

    # Spinner/ilerleme kalintilarini temizle (-, \, |, / ve fazla bos satirlar)
    $temizSatirlar = foreach ($satir in ($sonuc -split "`r?`n")) {
        $t = $satir.Trim()
        # Tek basina spinner karakteri olan satirlari atla
        if ($t -match '^[\\/|\-]+$') { continue }
        $satir
    }
    $sonuc = ($temizSatirlar -join "`r`n").Trim()

    # Sonucu ekrana yaz
    Write-Host $sonuc -ForegroundColor $Tema.Metin
    Write-Host ""

    if ($storeVar) {
        Write-Host "  Bilgi: Store mevcut. Tum paketler kurulabilir." -ForegroundColor $Tema.Soluk
    }
    Write-Host ""

    # --- Kurulacak ID al ---
    $id = Read-Host "  Kurmak icin uygulama ID'sini yazin (atlamak icin bos Enter)"
    if ([string]::IsNullOrWhiteSpace($id)) {
        Write-Host "  Kurulum atlandi." -ForegroundColor $Tema.Soluk
        Read-Host "  Devam etmek icin Enter'a basin"
        return
    }
    $id = $id.Trim()

    # --- Girilen ID'ye karsilik gelen UYGULAMA ADINI bul ---
    $secilenAd = $id   # bulunamazsa yedek olarak ID kalsin
    foreach ($satir in ($sonuc -split "`r?`n")) {
        if ($satir -match [regex]::Escape($id)) {
            $idKonum = $satir.IndexOf($id)
            if ($idKonum -gt 0) {
                $adKismi = $satir.Substring(0, $idKonum).Trim()
                if ($adKismi) { $secilenAd = $adKismi }
            }
            break
        }
    }

    Write-Host ""
    Write-Host "  '$secilenAd' kuruluyor..." -ForegroundColor $Tema.Vurgu
    Write-Host ""

    # --- Kurulumu yap ---
    winget install --id $id --accept-package-agreements --accept-source-agreements

    # --- Firewall servisi kapaliysa otomatik duzelt ve tekrar dene ---
    if ($LASTEXITCODE -eq -2147023143) {
        Write-Host "  Firewall servisi kapali. Baslatiliyor..." -ForegroundColor $Tema.Hata
        Start-Service BFE, mpssvc, Winmgmt -ErrorAction SilentlyContinue
        Write-Host "  Tekrar deneniyor..." -ForegroundColor $Tema.Vurgu
        winget install --id $id --accept-package-agreements --accept-source-agreements
    }

    Write-Host ""

    # --- Sonucu bildir ---
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) {
        Write-Result $true "'$secilenAd' basariyla kuruldu."
    } elseif ($LASTEXITCODE -eq -1978335212) {
        Write-Result $false "'$secilenAd' bulunamadi. ID'yi kontrol edin."
    } else {
        Write-Result $false "'$secilenAd' kurulamadi. (Hata kodu: $LASTEXITCODE)"
    }

    Write-Host ""
    Write-Host "  Ipucu: Kaldirmak icin ana menuden 'Uygulama Kaldir' secenegini kullanin." -ForegroundColor $Tema.Soluk
    Read-Host "  Devam etmek icin Enter'a basin"
}
function App-ExportImport {
    Show-Header "UYGULAMA LİSTESİ DIŞA/İÇE AKTAR"
    Write-Host "  1) Yüklü uygulama listesini dışa aktar (JSON)" -ForegroundColor White
    Write-Host "  2) JSON dosyasından uygulamaları içe aktar (kur)" -ForegroundColor White
    Write-Host ""

    if (-not $WingetVar) {
        Write-Result $false "Winget bulunamadı, bu işlem yapılamıyor."
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }

    $sec = Read-Host "  Seçiminiz (1/2)"
    if ($sec -eq "1") {
        $hedef = Select-Folder "JSON'un kaydedileceği klasörü seçin"
        if ($hedef) {
            $dosya = Join-Path $hedef "uygulama_listesi.json"
            winget export -o "$dosya" --accept-source-agreements | Out-Null
            if (Test-Path $dosya) {
                $boyutKB = [math]::Round((Get-Item $dosya).Length / 1KB, 1)
                Write-Result $true "Liste dışa aktarıldı: $dosya ($boyutKB KB)"
            } else {
                Write-Result $false "Dışa aktarma başarısız: dosya oluşturulamadı."
            }
        } else {
            Write-Result $false "İşlem iptal edildi."
        }
    } elseif ($sec -eq "2") {
        $dosya = Select-File
        if ($dosya) {
            $onay = Read-Host "  '$dosya' içindeki uygulamalar kurulacak. Onaylıyor musunuz? (E/H)"
            if ($onay -eq "E" -or $onay -eq "e") {

                Write-Host ""
                Write-Host "  Lütfen bekleyin, uygulamalar kuruluyor (canlı akacak)..." -ForegroundColor DarkGray
                Write-Host ""

                # Geçici log dosyası — HEM canlı ekrana ak HEM dosyaya yaz (sayım için)
                $geciciDosya = Join-Path $env:TEMP "winget_import_log.txt"

                winget import -i "$dosya" --disable-interactivity `
                    --accept-package-agreements --accept-source-agreements --ignore-unavailable 2>&1 |
                    Tee-Object -FilePath $geciciDosya
                $kod = $LASTEXITCODE

                # Sayım için dosyayı oku
                $ham = ""
                if (Test-Path $geciciDosya) { $ham = Get-Content $geciciDosya -Raw }
                Remove-Item $geciciDosya -ErrorAction SilentlyContinue

                # Sayım (regex ile — en güvenilir)
                $zatenKurulu = ([regex]::Matches($ham, "already installed")).Count
                $yeniKurulan = ([regex]::Matches($ham, "Successfully installed")).Count
                $toplam      = $zatenKurulu + $yeniKurulan

                # >>> ÖZET KUTUSU
                Write-Host ""
                Show-Top
                Show-Line "  İÇE AKTARMA ÖZETİ" $Tema.Vurgu
                Show-Divider
                Show-Line ("  Zaten kurulu      : " + $zatenKurulu + " uygulama") $Tema.Metin
                Show-Line ("  Yeni kurulan      : " + $yeniKurulan + " uygulama") $Tema.Basari
                Show-Divider
                Show-Line ("  İşlenen toplam    : " + $toplam + " uygulama") $Tema.Baslik
                Show-Bottom
                Write-Host ""

                if ($kod -eq 0) {
                    if ($yeniKurulan -gt 0) {
                        Write-Result $true "$yeniKurulan uygulama yeni kuruldu, $zatenKurulu uygulama zaten kuruluydu."
                    } else {
                        Write-Result $true "Tüm uygulamalar ($zatenKurulu) zaten kuruluydu — yeni kurulum gerekmedi."
                    }
                } else {
                    Write-Result $false "İçe aktarma tamamlandı ancak bazı uygulamalar kurulamadı (Kod: $kod)."
                }
            } else {
                Write-Result $false "İşlem iptal edildi."
            }
        } else {
            Write-Result $false "İşlem iptal edildi."
        }
    } else {
        Write-Result $false "Geçersiz seçim."
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function App-Uninstall {
    Show-Header "UYGULAMA KALDIR"
    Write-Host "  Yüklü tüm uygulamalar listeleniyor..." -ForegroundColor Yellow
    Write-Host ""
    if (-not $WingetVar) {
        Write-Result $false "Winget bulunamadı."
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
        return
    }
    winget list
    Write-Host ""
    Write-Host "  Yukarıdaki listeden kaldırmak istediğiniz uygulamanın" -ForegroundColor Cyan
    Write-Host "  ID veya Ad bilgisini girin (boş bırakıp Enter = iptal)." -ForegroundColor Cyan
    Write-Host ""
    $hedef = Read-Host "  Kaldırılacak uygulama (ID veya Ad)"
    if ([string]::IsNullOrWhiteSpace($hedef)) {
        Write-Result $false "İşlem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    # Ekranda gösterilecek etiket: başlangıçta girilen değer; gerçek ad bulununca güncellenir
    $gercekAd = $hedef

    $onay = Read-Host "  '$hedef' kaldırılsın mı? (E/H)"
    if ($onay -ne "E" -and $onay -ne "e") {
        Write-Result $false "İşlem iptal edildi."
        Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"; return
    }

    try {
        # --- KALDIRMA ÖNCESİ: uygulama gerçekten kurulu mu? ---
        $oncesi = (winget list --id $hedef 2>$null | Out-String)
        $varOncesiId = $oncesi -match [regex]::Escape($hedef)
        if (-not $varOncesiId) {
            $oncesiAd = (winget list --name $hedef 2>$null | Out-String)
            $varOncesiId = $oncesiAd -match [regex]::Escape($hedef)
        }

        # --- KALDIRMA: önce ID ile dene, çıktıyı YAKALA (adı buradan ayıklayacağız) ---
        $ciktiId = (winget uninstall --id $hedef --silent --accept-source-agreements 2>&1 | Out-String)
        $kod = $LASTEXITCODE
        $ciktiTum = $ciktiId

        if ($kod -ne 0) {
            Write-Host "  ID ile bulunamadı, Ad ile deneniyor..." -ForegroundColor DarkGray
            $ciktiAd = (winget uninstall --name $hedef --silent --accept-source-agreements 2>&1 | Out-String)
            $kod = $LASTEXITCODE
            $ciktiTum = $ciktiId + "`n" + $ciktiAd
        }

        # --- GERÇEK ADI winget çıktısından ayıkla:  "Found <Ad> [<Id>]" satırı ---
        # (winget dili TR olabilir: "Bulundu ..." de olabilir → sadece [Id] parantezine güven)
        $eslesme = [regex]::Match($ciktiTum, '(?im)^\s*(?:Found|Bulundu)\s+(?<ad>.+?)\s+\[[^\]]+\]\s*$')
        if ($eslesme.Success) {
            $gercekAd = $eslesme.Groups['ad'].Value.Trim()
        } else {
            # Yedek: "... [Id]" içeren herhangi bir satırdan köşeli parantez öncesini al
            $eslesme2 = [regex]::Match($ciktiTum, '(?m)^\s*(?<ad>.+?)\s+\[' + [regex]::Escape($hedef) + '\]')
            if ($eslesme2.Success) { $gercekAd = $eslesme2.Groups['ad'].Value.Trim() }
        }

        # --- KALDIRMA SONRASI DOĞRULAMA: gerçekten gitti mi? ---
        Start-Sleep -Seconds 1
        $sonrasi = (winget list --id $hedef 2>$null | Out-String)
        $halaVar = $sonrasi -match [regex]::Escape($hedef)
        if (-not $halaVar) {
            $sonrasiAd = (winget list --name $hedef 2>$null | Out-String)
            $halaVar = $sonrasiAd -match [regex]::Escape($hedef)
        }

        # --- SONUCU GERÇEK DURUMA GÖRE BİLDİR (artık gerçek adı gösterir) ---
        if (-not $varOncesiId) {
            Write-Result $false "'$gercekAd' zaten yüklü değildi (kaldırılacak bir şey yok)."
        } elseif (-not $halaVar) {
            Write-Result $true "'$gercekAd' başarıyla kaldırıldı ve doğrulandı."
        } else {
            Write-Result $false "'$gercekAd' hâlâ yüklü görünüyor (Kod: $kod). Kaldırma tamamlanamadı."
        }
    } catch {
        Write-Result $false "Kaldırma başarısız: $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Devam etmek için Enter'a basın"
}
function Show-Help {
    Show-Header "YARDIM / HAKKINDA"
    Write-Host "  Bilgisayar Aracı" -ForegroundColor $Tema.Vurgu
    Write-Host "  Hazırlayan : Mehmet IŞIK" -ForegroundColor $Tema.Metin
    Write-Host "  Güncelleme : 03.07.2026" -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "  Bu araç; uygulama kurulumu, sistem bilgisi," -ForegroundColor $Tema.Metin
    Write-Host "  bakım/temizlik ve sürücü yönetimi sağlar." -ForegroundColor $Tema.Metin
    Write-Host ""
    Write-Host "  • Numara yazıp Enter ile işlemi seçin." -ForegroundColor $Tema.Soluk
    Write-Host "  • 0 yazıp Enter ile programdan çıkın." -ForegroundColor $Tema.Soluk
    Write-Host ""
    if ($WingetVar) {
        Write-Host "  • Winget (paket yöneticisi): YÜKLÜ ✓" -ForegroundColor $Tema.Basari
    } else {
        Write-Host "  • Winget (paket yöneticisi): YÜKLÜ DEĞİL ✗" -ForegroundColor $Tema.Hata
        Write-Host "    Kurulum için aşağıdan 'E' seçebilirsiniz." -ForegroundColor $Tema.Soluk
    }
    Write-Host ""

    $wh = Read-Host "  Winget kurulum yardımını görüntülemek ister misiniz? (E/H)"
    if ($wh -eq "E" -or $wh -eq "e") {
        Show-WingetHelp
        # Kullanıcı yardımdan sonra winget kurduysa durumu güncelle
        $script:WingetVar = ($null -ne (Get-Command winget -ErrorAction SilentlyContinue))
    }
}

# ===================== UYGULAMA KURULUM EKRANI =====================

function Invoke-AppMenu {
    while ($true) {
        Show-Header "UYGULAMA KURULUMU"
        foreach ($u in $Uygulamalar) {
            $numara = "  " + $u.No.ToString().PadLeft(2) + ") "
            $satirAd = $u.Ad
            $tamSatir = $numara + $satirAd
            if ($tamSatir.Length -gt $BoxWidth) { $tamSatir = $tamSatir.Substring(0, $BoxWidth) }
            $bosluk = [math]::Max(1, $BoxWidth - $tamSatir.Length)
            Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
            Write-Host (" " + $numara) -ForegroundColor $Tema.Vurgu -NoNewline
            Write-Host ($satirAd + (" " * ($bosluk - 1))) -ForegroundColor $Tema.Baslik -NoNewline
            Write-Host "║" -ForegroundColor $Tema.Cerceve
        }
        Show-Divider
        Show-Line "  T) Seçili numaraları kur (örn: 1,3,5)" $Tema.Vurgu
        Show-Line "  H) Tümünü kur" $Tema.Vurgu
        Show-Line "  0) Ana menüye dön" $Tema.Soluk
        Show-Bottom
        Write-Host ""
        $sec = Read-Host "  Seçiminiz"

        if ($sec -eq "0") { return }

        # >>> YENİ: Kurulum denemesinden ÖNCE tek sefer winget kontrolü
        #     (Alpemix hariç — o winget'siz de çalışır. No=16)
        if ($sec -eq "H" -or $sec -eq "h" -or $sec -eq "T" -or $sec -eq "t" -or $sec -match "[0-9]") {
            # Kullanıcı yalnızca Alpemix (16) mı seçti? O zaman winget gerekmez.
            $secilenNolar = @()
            if ($sec -eq "H" -or $sec -eq "h") {
                $secilenNolar = $Uygulamalar.No
            } else {
                $secilenNolar = ($sec -split "[,\s]+" | Where-Object { $_ -match "^\d+$" } | ForEach-Object { [int]$_ })
            }
            # Alpemix dışında en az bir uygulama seçilmişse winget şart
            $wingetGerekli = $secilenNolar | Where-Object { $_ -ne 16 }

            if ($wingetGerekli -and -not $WingetVar) {
                Write-Host ""
                Write-Result $false "Winget kurulu olmadığı için uygulama kurulumu yapılamıyor."
                Write-Host ""
                Write-Host "  Winget'i kurmak için ana menü > 27) Yardım bölümünü kullanın" -ForegroundColor Yellow
                Write-Host "  veya programı yeniden başlatın (açılışta otomatik kurulmayı dener)." -ForegroundColor Yellow
                Write-Host ""
                Read-Host "  Devam etmek için Enter'a basın"
                continue   # menüye geri dön, kurulum DENEME
            }
        }

        if ($sec -eq "H" -or $sec -eq "h") {
            foreach ($u in $Uygulamalar) {
                Install-App $u.Ad $u.Id $u.Kaynak
            }
            Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"
        }
        elseif ($sec -eq "T" -or $sec -eq "t" -or $sec -match "[0-9]") {
            $numaralar = $sec -split "[,\s]+" | Where-Object { $_ -match "^\d+$" }
            foreach ($n in $numaralar) {
                $secilen = $Uygulamalar | Where-Object { $_.No -eq [int]$n }
                if ($secilen) {
                    Install-App $secilen.Ad $secilen.Id $secilen.Kaynak
                }
            }
            Write-Host ""; Read-Host "  Devam etmek için Enter'a basın"
        }
    }
}
# ===================== TEK DÜZ MENÜ (FLAT) =====================
# Tüm işlemler tek listede — alt menü yok. Numara yazıp Enter'a basın.
# Her satır: numara, başlık (grup), ve çalıştıracağı işlev.
$Menu = @(
    # ===== SOL SÜTUN (1–14) =====
    @{ No = 1;  Grup = "UYGULAMA";  Ad = "Uygulama Kurulumu (liste)";          Eylem = { Invoke-AppMenu } }
    @{ No = 2;  Grup = "UYGULAMA";  Ad = "Tüm Uygulamaları Güncelle";          Eylem = { Update-AllApps } }
    @{ No = 3;  Grup = "UYGULAMA";  Ad = "Uygulama Ara ve Kur (winget)";       Eylem = { Search-App } }
    @{ No = 4;  Grup = "UYGULAMA";  Ad = "Uygulama Listesi Dışa/İçe Aktar";    Eylem = { App-ExportImport } }
    @{ No = 5;  Grup = "UYGULAMA";  Ad = "Uygulama Kaldır";                    Eylem = { App-Uninstall } }

    @{ No = 6;  Grup = "TEMİZLİK";  Ad = "Geçici Dosyaları Temizle";           Eylem = { Clean-Temp } }
    @{ No = 7;  Grup = "TEMİZLİK";  Ad = "Windows Loglarını Temizle";          Eylem = { Clean-Logs } }
    @{ No = 8;  Grup = "TEMİZLİK";  Ad = "Windows Update Önbelleği";           Eylem = { Clean-WinUpdate } }
    @{ No = 9;  Grup = "TEMİZLİK";  Ad = "Geri Dönüşüm Kutusunu Boşalt";       Eylem = { Clean-RecycleBin } }
    @{ No = 10; Grup = "TEMİZLİK";  Ad = "Disk Temizleme (cleanmgr)";          Eylem = { Clean-Disk } }
    @{ No = 11; Grup = "TEMİZLİK";  Ad = "Ekran Kartı Sürücü Artıkları";       Eylem = { Clean-GpuLeftovers } }
    @{ No = 12; Grup = "TEMİZLİK";  Ad = "Sistem Dosyalarını Onar";            Eylem = { Repair-SystemFiles } }

    @{ No = 13; Grup = "SÜRÜCÜ";    Ad = "Sürücü Yedekle";                     Eylem = { Backup-Drivers } }
    @{ No = 14; Grup = "SÜRÜCÜ";    Ad = "Sürücü Geri Yükle";                  Eylem = { Restore-Drivers } }

    # ===== SAĞ SÜTUN (15–27) =====
    @{ No = 15; Grup = "BAKIM";     Ad = "Disk Kontrol ve Onarım (chkdsk)";    Eylem = { Repair-Disk } }
    @{ No = 16; Grup = "BAKIM";     Ad = "Güvenli USB Oluştur (Korumalı)";     Eylem = { Protect-USB } }
    @{ No = 17; Grup = "BAKIM";     Ad = "Windows Güncellemelerini Tara";      Eylem = { Start-WindowsUpdate } }
    @{ No = 18; Grup = "BAKIM";     Ad = "Ağ Ayarlarını Sıfırla";              Eylem = { Reset-Network } }
    @{ No = 19; Grup = "BAKIM";     Ad = "Geri Yükleme Noktası Oluştur";       Eylem = { New-RestorePoint } }
    @{ No = 20; Grup = "BAKIM";     Ad = "Yazıcı Kuyruğunu Temizle";           Eylem = { Clear-PrintQueue } }

    @{ No = 21; Grup = "BİLGİ";     Ad = "Sistem Bilgileri";                   Eylem = { Show-SystemInfo } }
    @{ No = 22; Grup = "BİLGİ";     Ad = "Disk Özeti";                         Eylem = { Show-DiskSummary } }
    @{ No = 23; Grup = "BİLGİ";     Ad = "Disk Sağlığı (SMART)";               Eylem = { Show-DiskHealth } }
    @{ No = 24; Grup = "BİLGİ";     Ad = "Başlangıç Programları";              Eylem = { Show-Startup } }
    @{ No = 25; Grup = "BİLGİ";     Ad = "Sistem Sağlık Özeti";                Eylem = { Show-HealthSummary } }

    @{ No = 26; Grup = "DİĞER";     Ad = "Yönetim Klasörleri Oluştur";         Eylem = { New-AdminFolders } }
    @{ No = 27; Grup = "DİĞER";     Ad = "Yardım / Hakkında";                  Eylem = { Show-Help } }
)

# ===================== YARDIMCI: MENÜ KOLONU OLUŞTUR =====================
# >>> REVİZE: Get-Kolon, Show-MainMenu'nün DIŞINA taşındı (her çizimde
#     yeniden tanımlanmasını önler). $ikon ve $Menu parametre olarak alınır.
function Get-Kolon {
    param(
        [string[]]$Gruplar,
        [hashtable]$Ikon,
        [array]$MenuListesi
    )
    $satirlar = @()
    foreach ($g in $Gruplar) {
        $ik = if ($Ikon.ContainsKey($g)) { $Ikon[$g] } else { "•" }
        $satirlar += [pscustomobject]@{ Tip = "Baslik"; Metin = (" " + $ik + " " + $g) }
        foreach ($m in ($MenuListesi | Where-Object { $_.Grup -eq $g })) {
            $satirlar += [pscustomobject]@{ Tip = "Oge"; No = $m.No; Ad = $m.Ad }
        }
    }
    return ,$satirlar
}

# ===================== ANA MENÜ (TEK DÜZ / FLAT) =====================
function Show-MainMenu {
    Clear-Host

    # ===== ÜST BAŞLIK BANDI =====
    Write-Host ("╔" + ("═" * $BoxWidth) + "╗") -ForegroundColor $Tema.Cerceve
    $baslik = "▙▖ B İ L G İ S A Y A R   A R A C I ▟▖"
    $bPad = [math]::Max(1, [math]::Floor(($BoxWidth - $baslik.Length) / 2))
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $bPad) + $baslik + (" " * ($BoxWidth - $baslik.Length - $bPad))) -ForegroundColor $Tema.Vurgu -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve
    $slogan = "Kur • Güncelle • Temizle • Yedekle • Onar"
    $sPad = [math]::Max(1, [math]::Floor(($BoxWidth - $slogan.Length) / 2))
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ((" " * $sPad) + $slogan + (" " * ($BoxWidth - $slogan.Length - $sPad))) -ForegroundColor $Tema.Soluk -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve

    # ===== CANLI MİNİ SİSTEM DURUMU =====
    $durum = " Sistem durumu okunuyor..."
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
        $cTop = [math]::Round($cDisk.Size / 1GB, 0)
        $cBos = [math]::Round($cDisk.FreeSpace / 1GB, 0)
        $cYuzde = if ($cTop -gt 0) { [math]::Round((($cTop - $cBos) / $cTop) * 100) } else { 0 }
        $ramBos = [math]::Round($os.FreePhysicalMemory / 1024 / 1024, 1)
        $durum = " 💽 C: %$cYuzde dolu ($cBos GB boş)   🧠 Boş RAM: $ramBos GB"
    } catch {}
    Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve
    $dPad = [math]::Max(1, $BoxWidth - $durum.Length)
    Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline
    Write-Host ($durum + (" " * $dPad)).Substring(0, $BoxWidth) -ForegroundColor $Tema.Basari -NoNewline
    Write-Host "║" -ForegroundColor $Tema.Cerceve
    Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve

    # ===== İKONLU GRUP DAĞILIMI (dengeli 12/12) =====
    $ikon = @{
        "UYGULAMA" = "📦"; "BİLGİ" = "ℹ️ "; "TEMİZLİK" = "🧹"
        "BAKIM"    = "🔧"; "SÜRÜCÜ" = "💾"; "DİĞER"    = "⚙️ "
    }
    $solGruplar = @("UYGULAMA", "TEMİZLİK", "SÜRÜCÜ")
    $sagGruplar = @("BAKIM", "BİLGİ", "DİĞER")

    # >>> REVİZE: Get-Kolon artık dışarıda; $ikon ve $Menu parametre geçiliyor
    $solKolon = Get-Kolon -Gruplar $solGruplar -Ikon $ikon -MenuListesi $Menu
    $sagKolon = Get-Kolon -Gruplar $sagGruplar -Ikon $ikon -MenuListesi $Menu

    $satirSayisi = [math]::Max($solKolon.Count, $sagKolon.Count)
    $kolGenislik = [math]::Floor(($BoxWidth - 1) / 2)
    $sagGen = $BoxWidth - $kolGenislik - 1

    for ($i = 0; $i -lt $satirSayisi; $i++) {
        $solSatir = if ($i -lt $solKolon.Count) { $solKolon[$i] } else { $null }
        $sagSatir = if ($i -lt $sagKolon.Count) { $sagKolon[$i] } else { $null }

        Write-Host "║" -ForegroundColor $Tema.Cerceve -NoNewline

        # --- SOL HÜCRE ---
        if (-not $solSatir) {
            Write-Host (" " * $kolGenislik) -NoNewline
        } elseif ($solSatir.Tip -eq "Baslik") {
            $m = $solSatir.Metin
            if ($m.Length -gt $kolGenislik) { $m = $m.Substring(0, $kolGenislik) }
            Write-Host ($m + (" " * [math]::Max(0, $kolGenislik - $m.Length))) -ForegroundColor $Tema.Vurgu -NoNewline
        } else {
            $num = "  " + $solSatir.No.ToString().PadLeft(2) + ") "
            $ad = $solSatir.Ad
            if (($num + $ad).Length -gt $kolGenislik) { $ad = $ad.Substring(0, [math]::Max(0, $kolGenislik - $num.Length)) }
            $pad = [math]::Max(0, $kolGenislik - ($num.Length + $ad.Length))
            Write-Host $num -ForegroundColor $Tema.Vurgu -NoNewline
            Write-Host ($ad + (" " * $pad)) -ForegroundColor $Tema.Baslik -NoNewline
        }

        Write-Host "│" -ForegroundColor $Tema.Cerceve -NoNewline

        # --- SAĞ HÜCRE ---
        if (-not $sagSatir) {
            Write-Host (" " * $sagGen) -NoNewline
        } elseif ($sagSatir.Tip -eq "Baslik") {
            $m = $sagSatir.Metin
            if ($m.Length -gt $sagGen) { $m = $m.Substring(0, $sagGen) }
            Write-Host ($m + (" " * [math]::Max(0, $sagGen - $m.Length))) -ForegroundColor $Tema.Vurgu -NoNewline
        } else {
            $num = "  " + $sagSatir.No.ToString().PadLeft(2) + ") "
            $ad = $sagSatir.Ad
            if (($num + $ad).Length -gt $sagGen) { $ad = $ad.Substring(0, [math]::Max(0, $sagGen - $num.Length)) }
            $pad = [math]::Max(0, $sagGen - ($num.Length + $ad.Length))
            Write-Host $num -ForegroundColor $Tema.Vurgu -NoNewline
            Write-Host ($ad + (" " * $pad)) -ForegroundColor $Tema.Baslik -NoNewline
        }

        Write-Host "║" -ForegroundColor $Tema.Cerceve
    }

# ===== ALT BANT =====
    Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve

    # >>> PRO DOKUNUŞ: Windows Terminal yüklü DEĞİLSE ipucu satırı göster
    $wtKurulu = $null -ne (Get-Command wt.exe -ErrorAction SilentlyContinue)
    if (-not $wtKurulu) {
        $wtPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
        if (Test-Path $wtPath) { $wtKurulu = $true }
    }
    if (-not $wtKurulu) {
        $ipucu = "  💡 Daha modern bir görünüm için Windows Terminal önerilir."
        $ipucu2 = "     Kurulum: Menü 1 (Uygulama Kurulumu) ▸ 15 numara."
        Show-Line $ipucu "Yellow"
        Show-Line $ipucu2 $Tema.Soluk
        Write-Host ("╟" + ("─" * $BoxWidth) + "╢") -ForegroundColor $Tema.Cerceve
    }

    Show-Line "  ➤ Numara yazıp Enter'a basın  •  0) Çıkış" $Tema.Vurgu
    Show-Line "  Mehmet IŞIK  •  Bilgisayar Aracı  •  v2026" $Tema.Soluk
    Write-Host ("╚" + ("═" * $BoxWidth) + "╝") -ForegroundColor $Tema.Cerceve
    Write-Host ""
}

# ===================== ANA DÖNGÜ (TEK MENÜ) =====================
$cikis = $false
do {
    try {
        Show-MainMenu
        $sec = Read-Host "  Seçiminiz"

        if ($sec -eq "0") {
            $cikis = $true
        }
        elseif ($sec -match "^\d+$") {
            $secilen = $Menu | Where-Object { $_.No -eq [int]$sec }
            if ($secilen) {
                & $secilen.Eylem
            } else {
                Write-Host ""
                Write-Host "  Geçersiz numara: $sec" -ForegroundColor Red
                Start-Sleep -Milliseconds 900
            }
        }
        else {
            Write-Host ""
            Write-Host "  Lütfen geçerli bir numara girin." -ForegroundColor Red
            Start-Sleep -Milliseconds 900
        }
    }
    catch {
        [Console]::CursorVisible = $true
        Write-Host ""
        Write-Host "  İŞLEM SIRASINDA HATA OLUŞTU:" -ForegroundColor Red
        Write-Host ("  " + $_.Exception.Message) -ForegroundColor Red
        Write-Host ""
        Read-Host "  Devam etmek için Enter'a basın"
    }
} while (-not $cikis)

Clear-Host
Write-Host "Program kapatıldı. İyi günler, Mehmet IŞIK!" -ForegroundColor Cyan
